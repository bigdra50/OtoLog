@preconcurrency import AVFAudio
import Foundation

// MARK: - RecordingSession

/// パイプライン統括。キャプチャ → エンジン → ストアを束ね、UI へ SessionEvent を流す。
///
/// チャンクはエンジンへ直結せずセッションが中継する。
/// キャプチャストリームの異常終了をここで検知し、エンジンを生かしたまま
/// キャプチャだけを再起動できるようにするため。
public actor RecordingSession {
    // MARK: Lifecycle

    public init(
        capture: any AudioCaptureSource,
        engine: any TranscriptionEngine,
        store: any TranscriptStore,
        translationTimeout: Duration = .seconds(10),
        source: AudioSourceKind = .system,
        now: @escaping @Sendable () -> Date = { Date() },
        makeSessionID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.capture = capture
        self.engine = engine
        self.store = store
        self.translationTimeout = translationTimeout
        self.source = source
        self.now = now
        self.makeSessionID = makeSessionID
        let (stream, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
        events = stream
        eventContinuation = continuation
    }

    // MARK: Public

    /// 単一消費者（UI）向けのイベント列
    public nonisolated let events: AsyncStream<SessionEvent>

    public private(set) var state: SessionState = .idle

    /// locales を複数渡すと、話されている言語をエンジンが選ぶ。先頭は判定できなかったときの既定。
    ///
    /// makeTranslator はセグメントのロケールを受けて翻訳器を作る。自動検出では開始時点で
    /// 翻訳元が決まらないため、生成を確定セグメントまで遅らせる。
    /// nil を返したロケールは訳さない（翻訳先が認識言語と同じ場合など）
    public func start(
        locales: [Locale],
        makeTranslator: (@Sendable (String) -> (any Translator)?)? = nil
    ) async {
        guard canStart, let primary = locales.first else { return }
        cleanUpPreviousRun()
        self.makeTranslator = makeTranslator
        translatorCache.removeAll()
        setState(.preparing)

        let continuation = eventContinuation
        let format: AVAudioFormat
        do {
            format = try await engine.prepare(locales: locales, onProgress: { progress in
                continuation.yield(.preparationProgress(progress))
            })
        } catch {
            setState(.failed(error.localizedDescription))
            return
        }
        analyzerFormat = format

        let (chunkStream, chunkContinuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        self.chunkContinuation = chunkContinuation

        // セッション識別子はここで発行し、engine（セグメント転写）と store（保存先）へ配る。
        // locale は候補の先頭。実際に話されていた言語はエンジンが判定してセグメントへ入れる
        let context = TranscriptionContext(
            locale: primary.identifier(.bcp47),
            source: source,
            sessionID: makeSessionID(),
            sessionStartedAt: now()
        )
        currentContext = context

        do {
            try await store.begin(context: context)
        } catch {
            setState(.failed(error.localizedDescription))
            return
        }

        let engineEvents: AsyncThrowingStream<TranscriptEvent, any Error>
        do {
            engineEvents = try await engine.start(chunks: chunkStream, context: context)
        } catch {
            setState(.failed(error.localizedDescription))
            return
        }
        startConsumer(engineEvents)

        do {
            try await startCaptureAndForward(format: format)
        } catch {
            setState(.failed(error.localizedDescription))
            return
        }
        setState(.recording)
    }

    public func stop() async {
        guard state == .recording || state == .preparing else { return }
        setState(.stopping)
        await capture.stop()
        // キャプチャストリームの正常終了（forwarding の完走）を待ってから閉じる
        await forwardingTask?.value
        chunkContinuation?.finish()
        await engine.finish()
        await consumerTask?.value
        // 全 append 完了後にセッションを閉じる。finalize 失敗は記録済みデータに影響しないため握る
        if let ref = try? await store.finalize(endedAt: now()) {
            eventContinuation.yield(.sessionFinished(ref))
        }
        setState(.idle)
    }

    // MARK: Private

    private let capture: any AudioCaptureSource
    private let engine: any TranscriptionEngine
    private let store: any TranscriptStore
    private let translationTimeout: Duration
    private let source: AudioSourceKind
    private let now: @Sendable () -> Date
    private let makeSessionID: @Sendable () -> UUID
    private nonisolated let eventContinuation: AsyncStream<SessionEvent>.Continuation

    /// start で受け取った翻訳器の生成手段。記録中は差し替わらない
    private var makeTranslator: (@Sendable (String) -> (any Translator)?)?
    /// ロケールごとの翻訳器。作れなかった場合も nil を覚えて作り直さない
    private var translatorCache: [String: (any Translator)?] = [:]
    private var currentContext: TranscriptionContext?
    private var analyzerFormat: AVAudioFormat?
    private var chunkContinuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation?
    private var forwardingTask: Task<Void, Never>?
    private var consumerTask: Task<Void, Never>?
    private var captureRestartCount = 0

    private var canStart: Bool {
        switch state {
        case .idle, .failed: true
        case .preparing, .recording, .stopping: false
        }
    }

    private func cleanUpPreviousRun() {
        chunkContinuation?.finish()
        forwardingTask?.cancel()
        consumerTask?.cancel()
        forwardingTask = nil
        consumerTask = nil
        captureRestartCount = 0
    }

    private func setState(_ newState: SessionState) {
        state = newState
        eventContinuation.yield(.stateChanged(newState))
    }

    private func startCaptureAndForward(format: AVAudioFormat) async throws {
        let stream = try await capture.start(targetFormat: format)
        guard let chunkContinuation else { return }
        forwardingTask = Task { [weak self] in
            do {
                for try await chunk in stream {
                    chunkContinuation.yield(chunk)
                }
                await self?.captureStreamEnded()
            } catch {
                await self?.captureStreamFailed(error)
            }
        }
    }

    private func captureStreamEnded() async {
        // stop() 経由の正常終了は .stopping で来る。録音中の無通告終了は障害として扱う
        if state == .recording {
            await attemptCaptureRestart(reason: "capture stream ended unexpectedly")
        }
    }

    private func captureStreamFailed(_ error: any Error) async {
        guard state == .recording else { return }
        await attemptCaptureRestart(reason: error.localizedDescription)
    }

    /// スリープ復帰などの一過性障害を想定して1回だけ再起動する。2回目は failed
    private func attemptCaptureRestart(reason: String) async {
        guard captureRestartCount == 0, let analyzerFormat else {
            setState(.failed(reason))
            return
        }
        captureRestartCount += 1
        do {
            try await startCaptureAndForward(format: analyzerFormat)
        } catch {
            setState(.failed(error.localizedDescription))
        }
    }

    private func startConsumer(_ engineEvents: AsyncThrowingStream<TranscriptEvent, any Error>) {
        consumerTask = Task { [weak self] in
            do {
                for try await event in engineEvents {
                    await self?.handle(event)
                }
            } catch {
                await self?.engineFailed(error)
            }
        }
    }

    private func handle(_ event: TranscriptEvent) async {
        switch event {
        case let .volatile(text):
            eventContinuation.yield(.liveTranscript(text))
        case let .finalized(segment):
            let segment = await translated(segment)
            do {
                try await store.append(segment)
                eventContinuation.yield(.segmentRecorded(segment))
            } catch {
                // 保存失敗でセッションは止めない。UI へ通知して継続する
                eventContinuation.yield(.storeError(error.localizedDescription))
            }
        }
    }

    /// 訳を載せて返す。翻訳器が無い・失敗・時間切れのときは原文のまま返し、記録は止めない
    private func translated(_ segment: TranscriptSegment) async -> TranscriptSegment {
        guard let translator = translator(for: segment.locale) else { return segment }
        do {
            let text = segment.text
            let result = try await withTimeout(translationTimeout) {
                try await translator.translate(text)
            }
            var translated = segment
            translated.translation = result.text
            translated.translationLocale = result.locale
            return translated
        } catch {
            eventContinuation.yield(.translationError(error.localizedDescription))
            return segment
        }
    }

    /// セグメントのロケールに対応する翻訳器。自動検出では話者の言語が確定してから作られる
    private func translator(for locale: String) -> (any Translator)? {
        if let cached = translatorCache[locale] { return cached }
        let created = makeTranslator?(locale)
        translatorCache[locale] = created
        return created
    }

    private func engineFailed(_ error: any Error) {
        if state == .recording {
            setState(.failed(error.localizedDescription))
        }
    }
}

// MARK: - TranslationTimeout

private struct TranslationTimeout: Error, LocalizedError {
    var errorDescription: String? {
        "翻訳が時間内に完了しませんでした。"
    }
}

/// duration 内に終わらなければ打ち切る。翻訳がハングしても確定セグメントの保存を止めないため。
/// 打ち切り後に翻訳が完了しても結果は捨てられる（group を抜けるときにキャンセルされる）
private func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TranslationTimeout()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw TranslationTimeout() }
        return result
    }
}
