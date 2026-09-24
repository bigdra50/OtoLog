@preconcurrency import AVFAudio
import Foundation

// MARK: - RecordingFeed

/// 1音源ぶんの録音構成。キャプチャとエンジンは1:1で対にする。
/// エンジンの start は1セッション1回の規約があり、複数音源で共有できない。
/// キャプチャも記録ごとに作り直す。失敗で畳んだ直後は、前の記録の再起動がまだそのキャプチャを止めている途中のことがある。
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
        restartPolicy: CaptureRestartPolicy = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        makeSessionID: @escaping @Sendable () -> UUID = { UUID() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.translationTimeout = translationTimeout
        self.restartPolicy = restartPolicy
        self.now = now
        self.makeSessionID = makeSessionID
        self.sleep = sleep
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
                setState(.failed(Self.failureReason(error.localizedDescription, from: feed.kind)))
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
            // 保存先の確保はどの音源にも属さないため、音源名は付けない
            setState(.failed(error.localizedDescription))
            return
        }

        for (index, feed) in feeds.enumerated() {
            var context = baseContext
            context.source = feed.kind
            do {
                try await activate(feed: feed, format: formats[index], context: context)
            } catch {
                await tearDownActiveFeeds()
                setState(.failed(Self.failureReason(error.localizedDescription, from: feed.kind)))
                return
            }
        }
        setState(.recording)
    }

    public func stop() async {
        guard state == .recording || state == .preparing else { return }
        setState(.stopping)
        // 再起動の途中のキャプチャは、.stopping を見た再起動が止める。ここからも止めると同じキャプチャへの呼び出しが重なる。
        // 再起動は forwarding の上で走るため、止め終えるのは下の完走待ちで一緒に待つ
        for slot in activeFeeds where !slot.isRestarting {
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
        if let ref = try? await store.finalize(endedAt: now(), reason: .stopped) {
            eventContinuation.yield(.sessionFinished(ref))
        }
        setState(.idle)
    }

    // MARK: Private

    /// 起動済みフィードの実行時状態。forwardingTask は再起動で差し替わる
    private struct FeedSlot: Identifiable {
        /// 待ちから戻った再起動が、同じスロットがまだ記録中かを確かめるための識別子。
        /// 添字では、畳んだ後に始まった次の記録のスロットと区別できない
        let id = UUID()
        let feed: RecordingFeed
        let format: AVAudioFormat
        var chunkContinuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation?
        var forwardingTask: Task<Void, Never>?
        var consumerTask: Task<Void, Never>?
        /// 連続して再起動した回数と、最後に再起動した時刻。数え直すかどうかは restartPolicy が決める
        var consecutiveRestarts = 0
        var lastRestartAt: Date?
        /// 再起動がキャプチャを止めてから、中継を再開するか起動に失敗するまでの間 true。
        /// この間キャプチャを止めるのも起動するのも再起動だけで、stop() と失敗の片付けは触れない。
        /// 実キャプチャは掴んでいるものを確かめてから解放するため、同じキャプチャへの呼び出しが重なると同じものを二重に解放する
        var isRestarting = false
    }

    private let store: any TranscriptStore
    private let translationTimeout: Duration
    private let restartPolicy: CaptureRestartPolicy
    private let now: @Sendable () -> Date
    private let makeSessionID: @Sendable () -> UUID
    private let sleep: @Sendable (Duration) async throws -> Void
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

    /// 音源に由来する失敗の理由へ音源名を付ける（「マイク: …」）。
    /// 複数音源の記録では、ポップオーバーとログでどちらが止まったかを見分けられないため
    private static func failureReason(_ reason: String, from source: AudioSourceKind) -> String {
        "\(source.displayName): \(reason)"
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
    private func activate(feed: RecordingFeed, format: AVAudioFormat, context: TranscriptionContext) async throws {
        let (chunkStream, chunkContinuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        let engineEvents = try await feed.engine.start(chunks: chunkStream, context: context)
        var slot = FeedSlot(feed: feed, format: format, chunkContinuation: chunkContinuation)
        slot.consumerTask = makeConsumerTask(engineEvents, source: feed.kind)
        activeFeeds.append(slot)
        try await startCaptureAndForward(slotID: slot.id)
    }

    /// 起動途中の失敗や記録中の恒久障害で、動いているものをすべて畳む。
    /// 片方の音源だけで録り続けると「揃った記録」に見えてしまうため、部分継続はしない。
    ///
    /// スロットはキャプチャを止める前に外す。畳んでいる間はまだ recording のままなので、
    /// 止めたキャプチャのストリーム終了がスロットに届くと、中断として再起動されてしまう。
    ///
    /// 再起動の途中のキャプチャは、スロットが外れたのを見た再起動が止める。
    /// 再起動の stop や start が終わるのは待たずに畳み、失敗をすぐ知らせる
    private func tearDownActiveFeeds() async {
        let slots = activeFeeds
        activeFeeds.removeAll()
        for slot in slots {
            if !slot.isRestarting {
                await slot.feed.capture.stop()
            }
            slot.chunkContinuation?.finish()
            slot.forwardingTask?.cancel()
            slot.consumerTask?.cancel()
        }
    }

    private func activeIndex(of slotID: FeedSlot.ID) -> Int? {
        activeFeeds.firstIndex { $0.id == slotID }
    }

    /// スロットのキャプチャを起動し、チャンクをそのフィードのエンジンへ中継する。
    /// 起動を待つ間に停止や失敗の片付けでスロットが外れていたら、起動したキャプチャを止めて中継しない。
    /// 止めないと、誰も止めないキャプチャがデバイスを掴んだまま残る
    private func startCaptureAndForward(slotID: FeedSlot.ID) async throws {
        guard let index = activeIndex(of: slotID) else { return }
        let slot = activeFeeds[index]
        let stream = try await slot.feed.capture.start(targetFormat: slot.format)
        guard state == .preparing || state == .recording,
              let index = activeIndex(of: slotID),
              let chunkContinuation = slot.chunkContinuation
        else {
            await slot.feed.capture.stop()
            return
        }
        // 中継を始めたキャプチャは、再起動したものも stop() と失敗の片付けが止める。
        // 中継の開始と同じ区切りで受け持ちを戻し、止める側がいないキャプチャを作らない
        activeFeeds[index].isRestarting = false
        activeFeeds[index].forwardingTask = Task { [weak self] in
            do {
                for try await chunk in stream {
                    chunkContinuation.yield(chunk)
                }
                await self?.attemptCaptureRestart(slotID: slotID, reason: "capture stream ended unexpectedly")
            } catch {
                await self?.attemptCaptureRestart(slotID: slotID, reason: error.localizedDescription)
            }
        }
    }

    /// スリープ復帰や音声構成の変更による一過性の中断を想定して、そのフィードのキャプチャだけを再起動する。
    /// 何回まで続けて再起動するか、いつ数え直すかは restartPolicy が決める。
    /// 中断は再起動するかどうかにかかわらず毎回 captureInterrupted で流す
    private func attemptCaptureRestart(slotID: FeedSlot.ID, reason: String) async {
        // stop() 経由の正常終了は .stopping で来る。スロットが無いのは、外した後のキャプチャ
        // （畳んでいる最中や前回の記録のもの）の終了が届いたとき。どちらも中断ではないので何もしない。
        // ここで failed にすると、無関係な理由の failed が本来の理由より先に流れる
        guard state == .recording, let index = activeIndex(of: slotID) else { return }
        let slot = activeFeeds[index]
        let decision = restartPolicy.decision(
            consecutiveRestarts: slot.consecutiveRestarts, lastRestartAt: slot.lastRestartAt, now: now()
        )
        guard case let .restart(attempt) = decision else {
            await giveUpCapture(source: slot.feed.kind, reason: reason)
            return
        }
        eventContinuation.yield(.captureInterrupted(CaptureInterruption(
            source: slot.feed.kind, reason: reason, restartAttempt: attempt
        )))
        // ここから中継を再開するまで、このキャプチャへの呼び出しは再起動だけが行う。
        // 止まったキャプチャが掴んでいるものを、待つ間も持ち続けないよう先に止める。
        // 1回の構成変更で中断の通知は続けて届くため、落ち着くのを待ってから再起動する
        activeFeeds[index].isRestarting = true
        await slot.feed.capture.stop()
        do {
            try await sleep(restartPolicy.settleDelay)
        } catch {
            // 待ちが投げるのは、失敗の片付けで forwarding ごとキャンセルされたとき
            return
        }
        // actor は再入するため、待つ間に stop や失敗の片付けが走り、次の記録が始まっていることもある
        guard state == .recording, let index = activeIndex(of: slotID) else { return }
        // 時刻は起動の直前に取る。数え直しは、再起動してから動いた時間で決めるため
        activeFeeds[index].consecutiveRestarts = attempt
        activeFeeds[index].lastRestartAt = now()
        do {
            try await startCaptureAndForward(slotID: slotID)
        } catch {
            // 起動できなかったのも連続した中断の1回として数え、同じ手順でやり直すか諦める。
            // 起動を待つ間（許可の確認など）に stableInterval が過ぎても数え直さないよう、時刻は失敗した時点に取り直す。
            // 動いていないキャプチャの受け持ちは戻し、諦めて畳むときは他のフィードと同じく止めさせる
            if let index = activeIndex(of: slotID) {
                activeFeeds[index].lastRestartAt = now()
                activeFeeds[index].isRestarting = false
            }
            await attemptCaptureRestart(slotID: slotID, reason: error.localizedDescription)
        }
    }

    private func giveUpCapture(source: AudioSourceKind, reason: String) async {
        eventContinuation.yield(.captureInterrupted(CaptureInterruption(
            source: source, reason: reason, restartAttempt: nil
        )))
        await failSession(Self.failureReason(reason, from: source))
    }

    private func failSession(_ reason: String) async {
        await tearDownActiveFeeds()
        setState(.failed(reason))
    }

    private func makeConsumerTask(
        _ engineEvents: AsyncThrowingStream<TranscriptEvent, any Error>,
        source: AudioSourceKind
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await event in engineEvents {
                    await self?.handle(event)
                }
            } catch {
                await self?.engineFailed(error, source: source)
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

    private func engineFailed(_ error: any Error, source: AudioSourceKind) async {
        if state == .recording {
            await failSession(Self.failureReason(error.localizedDescription, from: source))
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
