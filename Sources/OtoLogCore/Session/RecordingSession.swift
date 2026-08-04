@preconcurrency import AVFAudio
import Foundation

// MARK: - RecordingFeed

/// 1音源ぶんの録音構成。キャプチャとエンジンは1:1で対にする。
/// エンジンの start は1セッション1回の規約があり、複数音源で共有できない。
/// kind はセグメントの source（話者区別の根拠）としてそのまま保存される
public struct RecordingFeed: Sendable {
    // MARK: Lifecycle

    public init(capture: any AudioCaptureSource, engine: any TranscriptionEngine, kind: AudioSourceKind) {
        self.capture = capture
        self.engine = engine
        self.kind = kind
    }

    // MARK: Public

    public let capture: any AudioCaptureSource
    public let engine: any TranscriptionEngine
    public let kind: AudioSourceKind
}

// MARK: - RecordingSession

/// パイプライン統括。フィード（キャプチャ + エンジン）の組を束ね、
/// 確定セグメントを1つのストアへ集約して UI へ SessionEvent を流す。
///
/// チャンクはエンジンへ直結せずセッションが中継する。
/// キャプチャストリームの異常終了をここで検知し、エンジンを生かしたまま
/// そのフィードのキャプチャだけを再起動できるようにするため。
public actor RecordingSession {
    // MARK: Lifecycle

    public init(
        store: any TranscriptStore,
        translationTimeout: Duration = .seconds(10),
        now: @escaping @Sendable () -> Date = { Date() },
        makeSessionID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.store = store
        self.translationTimeout = translationTimeout
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

    /// feeds の全フィードを同じセッション（同じ保存先）として起動する。
    /// どれか1つでも起動に失敗したら全体を failed にする（欠けた音源に気づかないまま録り続けない）。
    ///
    /// locales を複数渡すと、話されている言語を各エンジンが選ぶ。先頭は判定できなかったときの既定。
    ///
    /// makeTranslator はセグメントのロケールを受けて翻訳器を作る。自動検出では開始時点で
    /// 翻訳元が決まらないため、生成を確定セグメントまで遅らせる。
    /// nil を返したロケールは訳さない（翻訳先が認識言語と同じ場合など）
    public func start(
        feeds: [RecordingFeed],
        locales: [Locale],
        makeTranslator: (@Sendable (String) -> (any Translator)?)? = nil
    ) async {
        guard canStart, !feeds.isEmpty, let primary = locales.first else { return }
        cleanUpPreviousRun()
        self.makeTranslator = makeTranslator
        translatorCache.removeAll()
        setState(.preparing)

        let continuation = eventContinuation
        // 認識モデルの確保はフィードごとに直列で行う。アセットはシステム共有のため
        // 2本目以降のダウンロードは実質即時に終わる（進捗が混ざって表示される心配はない）
        var formats: [AVAudioFormat] = []
        for feed in feeds {
            do {
                let format = try await feed.engine.prepare(locales: locales, onProgress: { progress in
                    continuation.yield(.preparationProgress(progress))
                })
                formats.append(format)
            } catch {
                setState(.failed(error.localizedDescription))
                return
            }
        }

        // セッション識別子はここで発行し、全フィードの engine と store へ配る。
        // locale は候補の先頭。実際に話されていた言語はエンジンが判定してセグメントへ入れる
        let baseContext = TranscriptionContext(
            locale: primary.identifier(.bcp47),
            source: feeds[0].kind, // 保存先は1つなので meta の source は先頭フィードを代表にする
            sessionID: makeSessionID(),
            sessionStartedAt: now()
        )

        do {
            try await store.begin(context: baseContext)
        } catch {
            setState(.failed(error.localizedDescription))
            return
        }

        for (index, feed) in feeds.enumerated() {
            var context = baseContext
            context.source = feed.kind
            do {
                try await activate(feed: feed, index: index, format: formats[index], context: context)
            } catch {
                await tearDownActiveFeeds()
                setState(.failed(error.localizedDescription))
                return
            }
        }
        setState(.recording)
    }

    public func stop() async {
        guard state == .recording || state == .preparing else { return }
        setState(.stopping)
        for slot in activeFeeds {
            await slot.feed.capture.stop()
        }
        // キャプチャストリームの正常終了（forwarding の完走）を待ってから閉じる
        for slot in activeFeeds {
            await slot.forwardingTask?.value
        }
        for slot in activeFeeds {
            slot.chunkContinuation?.finish()
        }
        for slot in activeFeeds {
            await slot.feed.engine.finish()
        }
        for slot in activeFeeds {
            await slot.consumerTask?.value
        }
        activeFeeds.removeAll()
        // 全 append 完了後にセッションを閉じる。finalize 失敗は記録済みデータに影響しないため握る
        if let ref = try? await store.finalize(endedAt: now()) {
            eventContinuation.yield(.sessionFinished(ref))
        }
        setState(.idle)
    }

    // MARK: Private

    /// 起動済みフィードの実行時状態。forwardingTask は再起動で差し替わる
    private struct FeedSlot {
        let feed: RecordingFeed
        let format: AVAudioFormat
        var chunkContinuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation?
        var forwardingTask: Task<Void, Never>?
        var consumerTask: Task<Void, Never>?
        var restartCount = 0
    }

    private let store: any TranscriptStore
    private let translationTimeout: Duration
    private let now: @Sendable () -> Date
    private let makeSessionID: @Sendable () -> UUID
    private nonisolated let eventContinuation: AsyncStream<SessionEvent>.Continuation

    /// start で受け取った翻訳器の生成手段。記録中は差し替わらない
    private var makeTranslator: (@Sendable (String) -> (any Translator)?)?
    /// ロケールごとの翻訳器。作れなかった場合も nil を覚えて作り直さない
    private var translatorCache: [String: (any Translator)?] = [:]
    private var activeFeeds: [FeedSlot] = []

    private var canStart: Bool {
        switch state {
        case .idle, .failed: true
        case .preparing, .recording, .stopping: false
        }
    }

    private func cleanUpPreviousRun() {
        for slot in activeFeeds {
            slot.chunkContinuation?.finish()
            slot.forwardingTask?.cancel()
            slot.consumerTask?.cancel()
        }
        activeFeeds.removeAll()
    }

    private func setState(_ newState: SessionState) {
        state = newState
        eventContinuation.yield(.stateChanged(newState))
    }

    /// エンジン起動 → スロット登録 → キャプチャ起動。スロットは capture.start の失敗時にも
    /// 積まれた状態で残し、呼び出し側の tearDownActiveFeeds で畳ませる
    private func activate(
        feed: RecordingFeed, index: Int, format: AVAudioFormat, context: TranscriptionContext
    ) async throws {
        let (chunkStream, chunkContinuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        let engineEvents = try await feed.engine.start(chunks: chunkStream, context: context)
        var slot = FeedSlot(feed: feed, format: format, chunkContinuation: chunkContinuation)
        slot.consumerTask = makeConsumerTask(engineEvents)
        activeFeeds.append(slot)
        try await startCaptureAndForward(at: index)
    }

    /// 起動途中の失敗や記録中の恒久障害で、動いているものをすべて畳む。
    /// 片方の音源だけで録り続けると「揃った記録」に見えてしまうため、部分継続はしない
    private func tearDownActiveFeeds() async {
        for slot in activeFeeds {
            await slot.feed.capture.stop()
            slot.chunkContinuation?.finish()
            slot.forwardingTask?.cancel()
            slot.consumerTask?.cancel()
        }
        activeFeeds.removeAll()
    }

    private func startCaptureAndForward(at index: Int) async throws {
        let slot = activeFeeds[index]
        let stream = try await slot.feed.capture.start(targetFormat: slot.format)
        guard let chunkContinuation = slot.chunkContinuation else { return }
        activeFeeds[index].forwardingTask = Task { [weak self] in
            do {
                for try await chunk in stream {
                    chunkContinuation.yield(chunk)
                }
                await self?.captureStreamEnded(at: index)
            } catch {
                await self?.captureStreamFailed(at: index, error)
            }
        }
    }

    private func captureStreamEnded(at index: Int) async {
        // stop() 経由の正常終了は .stopping で来る。録音中の無通告終了は障害として扱う
        if state == .recording {
            await attemptCaptureRestart(at: index, reason: "capture stream ended unexpectedly")
        }
    }

    private func captureStreamFailed(at index: Int, _ error: any Error) async {
        guard state == .recording else { return }
        await attemptCaptureRestart(at: index, reason: error.localizedDescription)
    }

    /// スリープ復帰などの一過性障害を想定して、そのフィードだけを1回再起動する。2回目は failed
    private func attemptCaptureRestart(at index: Int, reason: String) async {
        guard index < activeFeeds.count, activeFeeds[index].restartCount == 0 else {
            await failSession(reason)
            return
        }
        activeFeeds[index].restartCount += 1
        do {
            try await startCaptureAndForward(at: index)
        } catch {
            await failSession(error.localizedDescription)
        }
    }

    private func failSession(_ reason: String) async {
        await tearDownActiveFeeds()
        setState(.failed(reason))
    }

    private func makeConsumerTask(
        _ engineEvents: AsyncThrowingStream<TranscriptEvent, any Error>
    ) -> Task<Void, Never> {
        Task { [weak self] in
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

    private func engineFailed(_ error: any Error) async {
        if state == .recording {
            await failSession(error.localizedDescription)
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
