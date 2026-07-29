import AppKit
import Foundation
import OtoLogCore

/// SessionEvent → AppState の反映と、UI 操作の Core への転送だけを行う薄いブリッジ。
@MainActor final class RecordingCoordinator {
    // MARK: Lifecycle

    init(session: RecordingSession, store: SessionFileStore, state: AppState, settings: AppSettings) {
        self.session = session
        self.store = store
        self.state = state
        self.settings = settings
    }

    // MARK: Internal

    /// 停止完了時に呼ばれるフック（AppDelegate が GenerationCoordinator へ配線する）
    var onSessionFinished: ((SessionRef) -> Void)?

    static func makeDefault(state: AppState, settings: AppSettings) -> RecordingCoordinator {
        let store = SessionFileStore(directory: settings.saveDirectory, timeZone: .current)
        let session = RecordingSession(
            capture: ProcessTapCaptureSource(),
            engine: SpeechAnalyzerEngine(),
            store: store
        )
        return RecordingCoordinator(session: session, store: store, state: state, settings: settings)
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
        let locale = Locale(identifier: settings.localeIdentifier)
        Task { [session, state] in
            if state.isRecording {
                await session.stop()
            } else {
                await session.start(locale: locale)
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
        let reader = TranscriptReader(directory: settings.saveDirectory, timeZone: .current)
        guard let latest = reader.availableSessions().first else {
            openSaveFolder()
            return
        }
        let sessionDir = settings.saveDirectory.appendingPathComponent(latest.directoryName)
        let markdown = sessionDir.appendingPathComponent("transcript.md")
        let target = FileManager.default.fileExists(atPath: markdown.path) ? markdown : sessionDir
        NSWorkspace.shared.open(target)
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

    // MARK: Private

    private let session: RecordingSession
    private let store: SessionFileStore
    private let state: AppState
    private let settings: AppSettings
    private var eventTask: Task<Void, Never>?

    private func apply(_ event: SessionEvent) {
        switch event {
        case let .stateChanged(sessionState):
            state.sessionState = sessionState
            if sessionState == .recording {
                state.storeErrorMessage = nil
            }
            if sessionState == .idle {
                state.liveText = ""
            }
        case let .preparationProgress(progress):
            state.preparationProgress = progress
        case let .liveTranscript(text):
            state.liveText = text
        case let .segmentRecorded(segment):
            state.lastSegmentText = segment.text
            state.liveText = ""
        case let .storeError(message):
            state.storeErrorMessage = message
        case let .sessionFinished(ref):
            onSessionFinished?(ref)
        }
    }
}
