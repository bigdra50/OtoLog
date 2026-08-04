import AppKit
import Foundation
import OtoLogCore

/// SessionEvent → AppState の反映と、UI 操作の Core への転送だけを行う薄いブリッジ。
@MainActor final class RecordingCoordinator {
    // MARK: Lifecycle

    init(
        session: RecordingSession,
        store: SessionFileStore,
        state: AppState,
        settings: AppSettings,
        overlay: SubtitleOverlayController = SubtitleOverlayController()
    ) {
        self.session = session
        self.store = store
        self.state = state
        self.settings = settings
        self.overlay = overlay
    }

    // MARK: Internal

    /// 停止完了時に呼ばれるフック（AppDelegate が GenerationCoordinator へ配線する）
    var onSessionFinished: ((SessionRef) -> Void)?

    static func makeDefault(state: AppState, settings: AppSettings) -> RecordingCoordinator {
        let store = SessionFileStore(directory: settings.saveDirectory, timeZone: .current)
        return RecordingCoordinator(
            session: RecordingSession(store: store), store: store, state: state, settings: settings
        )
    }

    func startObserving() {
        eventTask = Task { [weak self] in
            guard let events = self?.session.events else { return }
            for await event in events {
                self?.apply(event)
            }
        }
    }

    func toggle() {
        let locales = recognitionLocales()
        let makeTranslator = translatorFactory()
        let feeds = makeFeeds()
        Task { [session, state] in
            if state.isRecording {
                await session.stop()
            } else {
                await session.start(feeds: feeds, locales: locales, makeTranslator: makeTranslator)
            }
        }
    }

    func stopIfRecording() {
        Task { [session] in
            await session.stop()
        }
    }

    /// 最新セッションの transcript.md を開く。セッションが無ければ保存フォルダを開く
    func openLatestSession() {
        let directory = settings.saveDirectory
        Task { [weak self] in
            let target = await OffMainIO.read { () -> URL? in
                let reader = TranscriptReader(directory: directory, timeZone: .current)
                guard let latest = reader.availableSessions().first else { return nil }
                let sessionDir = directory.appendingPathComponent(latest.directoryName)
                let markdown = sessionDir.appendingPathComponent("transcript.md")
                return FileManager.default.fileExists(atPath: markdown.path) ? markdown : sessionDir
            }
            if let target {
                NSWorkspace.shared.open(target)
            } else {
                self?.openSaveFolder()
            }
        }
    }

    /// 記録の保存フォルダを開く
    func openSaveFolder() {
        Task { [store] in
            let root = await store.rootDirectory()
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            _ = await MainActor.run {
                NSWorkspace.shared.open(root)
            }
        }
    }

    func updateSaveDirectory(_ url: URL) {
        settings.saveDirectoryPath = url.path
        Task { [store] in
            await store.updateDirectory(url)
        }
    }

    func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: 制御ソケット（CLI・エージェントの正規経路。UI と同じ操作を AX なしで提供する）

    func controlStatus() async -> ControlResponse {
        await ControlResponse(
            ok: true, state: Self.describe(session.state), sessionPath: latestSessionPath()
        )
    }

    /// 状態遷移（recording / failed）の完了まで待って結果を返す。二重開始は reject
    func controlStart() async -> ControlResponse {
        let before = await session.state
        guard before == .idle || Self.isFailed(before) else {
            return await ControlResponse(
                ok: false, error: "既に記録中です",
                state: Self.describe(before), sessionPath: latestSessionPath()
            )
        }
        await session.start(
            feeds: makeFeeds(), locales: recognitionLocales(), makeTranslator: translatorFactory()
        )
        let after = await session.state
        if case let .failed(message) = after {
            return ControlResponse(ok: false, error: message, state: Self.describe(after))
        }
        return await ControlResponse(
            ok: after == .recording, state: Self.describe(after), sessionPath: latestSessionPath()
        )
    }

    func controlStop() async -> ControlResponse {
        let before = await session.state
        guard before == .recording || before == .preparing else {
            return await ControlResponse(
                ok: false, error: "記録していません",
                state: Self.describe(before), sessionPath: latestSessionPath()
            )
        }
        await session.stop()
        return await ControlResponse(
            ok: true, state: Self.describe(session.state), sessionPath: latestSessionPath()
        )
    }

    // MARK: Private

    private let session: RecordingSession
    private let store: SessionFileStore
    private let state: AppState
    private let settings: AppSettings
    private let overlay: SubtitleOverlayController
    private var eventTask: Task<Void, Never>?

    private static func describe(_ state: SessionState) -> String {
        switch state {
        case .idle: "idle"
        case .preparing: "preparing"
        case .recording: "recording"
        case .stopping: "stopping"
        case .failed: "failed"
        }
    }

    private static func isFailed(_ state: SessionState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func recognitionLocales() -> [Locale] {
        settings.resolvedRecognitionLocales.map { Locale(identifier: $0) }
    }

    /// 設定の入力モードからフィード（キャプチャ + エンジンの対）を組む。
    /// キャプチャとエンジンは開始のたびに新規生成し、前回セッションの状態を持ち越さない
    private func makeFeeds() -> [RecordingFeed] {
        let mode = settings.audioInputMode
        var feeds: [RecordingFeed] = []
        if mode != .microphoneOnly {
            feeds.append(RecordingFeed(
                capture: ProcessTapCaptureSource(), engine: SpeechAnalyzerEngine(), kind: .system
            ))
        }
        if mode.usesMicrophone {
            feeds.append(RecordingFeed(
                capture: MicrophoneCaptureSource(deviceUID: settings.microphoneDeviceUID),
                engine: SpeechAnalyzerEngine(),
                kind: .microphone
            ))
        }
        return feeds
    }

    /// 翻訳器はセグメントのロケールが決まってから作る。自動検出では開始時点で翻訳元が分からない。
    /// 翻訳オフ、または翻訳先が認識言語と同じときは nil になり、訳さずに記録される
    private func translatorFactory() -> (@Sendable (String) -> (any Translator)?)? {
        guard settings.translationEnabled else { return nil }
        let target = settings.resolvedTranslationTarget
        return { source in AppleTranslator(sourceLocale: source, targetLocale: target) }
    }

    /// 制御応答は自動化経路のため utility で足りる
    private func latestSessionPath() async -> String? {
        let directory = settings.saveDirectory
        return await OffMainIO.read(priority: .utility) {
            TranscriptReader(directory: directory, timeZone: .current)
                .availableSessions().first?.directoryName
        }
    }

    private func apply(_ event: SessionEvent) {
        switch event {
        case let .stateChanged(sessionState):
            state.sessionState = sessionState
            if sessionState == .recording {
                state.storeErrorMessage = nil
                state.translationErrorMessage = nil
            }
            if sessionState == .idle {
                state.liveText = ""
            }
            if sessionState != .recording {
                overlay.hide()
            }
        case let .preparationProgress(progress):
            state.preparationProgress = progress
        case let .liveTranscript(text):
            state.liveText = text
        case let .segmentRecorded(segment):
            state.lastSegmentText = segment.text
            state.lastSegmentTranslation = segment.translation ?? ""
            state.liveText = ""
            if let translation = segment.translation, settings.subtitleOverlayEnabled {
                overlay.update(original: segment.text, translation: translation)
            }
        case let .storeError(message):
            state.storeErrorMessage = message
        case let .translationError(message):
            state.translationErrorMessage = message
        case let .sessionFinished(ref):
            onSessionFinished?(ref)
        }
    }
}
