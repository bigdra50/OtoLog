@preconcurrency import AVFAudio
import Foundation

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
        source: AudioSourceKind = .system,
        now: @escaping @Sendable () -> Date = { Date() },
        makeSessionID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.capture = capture
        self.engine = engine
        self.store = store
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

    public func start(locale: Locale) async {
        guard canStart else { return }
        cleanUpPreviousRun()
        setState(.preparing)

        let continuation = eventContinuation
        let format: AVAudioFormat
        do {
            format = try await engine.prepare(locale: locale, onProgress: { progress in
                continuation.yield(.preparationProgress(progress))
            })
        } catch {
            setState(.failed(error.localizedDescription))
            return
        }
        analyzerFormat = format

        let (chunkStream, chunkContinuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        self.chunkContinuation = chunkContinuation

        // セッション識別子はここで発行し、engine（セグメント転写）と store（保存先）へ配る
        let context = TranscriptionContext(
            locale: locale.identifier(.bcp47),
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
    private let source: AudioSourceKind
    private let now: @Sendable () -> Date
    private let makeSessionID: @Sendable () -> UUID
    private nonisolated let eventContinuation: AsyncStream<SessionEvent>.Continuation

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
            do {
                try await store.append(segment)
                eventContinuation.yield(.segmentRecorded(segment))
            } catch {
                // 保存失敗でセッションは止めない。UI へ通知して継続する
                eventContinuation.yield(.storeError(error.localizedDescription))
            }
        }
    }

    private func engineFailed(_ error: any Error) {
        if state == .recording {
            setState(.failed(error.localizedDescription))
        }
    }
}
