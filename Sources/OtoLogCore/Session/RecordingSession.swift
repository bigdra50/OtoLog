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
    /// 待っている間に stop() や失敗で閉じられたら、.recording に入らずに終える。
    /// 閉じるのは閉じた側で、ここは待つ間に自分が起動したもの（閉じる側が知らないもの）だけを後始末する。
    ///
    /// locales を複数渡すと、話されている言語を各エンジンが選ぶ。先頭は判定できなかったときの既定。
    ///
    /// makeTranslator はセグメントのロケールを受けて翻訳器を作る。自動検出では開始時点で
    /// 翻訳元が決まらないため、生成を確定セグメントまで遅らせる。
    /// nil を返したロケールは訳さない（翻訳先が認識言語と同じ場合など）
    ///
    /// silenceTimeout を渡すと、記録中にどの音源からも発話（文字か数字を含む途中経過か確定結果）が届かないまま
    /// その長さが過ぎたところで、autoStopped を知らせて停止と同じ手順で閉じる。nil なら無音では止めない
    public func start(
        feeds: [RecordingFeed],
        locales: [Locale],
        makeTranslator: (@Sendable (String) -> (any Translator)?)? = nil,
        silenceTimeout: Duration? = nil
    ) async {
        guard canStart, !feeds.isEmpty, let primary = locales.first else { return }
        let run = UUID()
        runID = run
        self.makeTranslator = makeTranslator
        translatorCache.removeAll()
        recordedSegmentCount = 0
        storeBegin = nil
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
                // 閉じられた後の失敗は、閉じた側が決めた終わり方を上書きしない
                guard isPreparing(run) else { return }
                setState(.failed(Self.failureReason(error.localizedDescription, from: feed.kind)))
                return
            }
            guard isPreparing(run) else { return }
        }

        // セッション識別子はここで発行し、全フィードの engine と store へ配る。
        // locale は候補の先頭。実際に話されていた言語はエンジンが判定してセグメントへ入れる
        let baseContext = TranscriptionContext(
            locale: primary.identifier(.bcp47),
            source: feeds[0].kind, // 保存先は1つなので meta の source は先頭フィードを代表にする
            sessionID: makeSessionID(),
            sessionStartedAt: now()
        )

        // 確保の途中で閉じられても、閉じる側が確保の終わりを待ってから閉じられるよう Task で持つ
        let begin = Task { [store] in try await store.begin(context: baseContext) }
        storeBegin = begin
        do {
            try await begin.value
        } catch {
            guard isPreparing(run) else { return }
            // 保存先の確保はどの音源にも属さないため、音源名は付けない
            setState(.failed(error.localizedDescription))
            return
        }
        guard isPreparing(run) else { return }

        for (index, feed) in feeds.enumerated() {
            var context = baseContext
            context.source = feed.kind
            do {
                try await activate(feed: feed, format: formats[index], context: context, run: run)
            } catch {
                guard isPreparing(run) else { return }
                // 保存先は確保済みなので、起動したものを止めて空のセッションとして閉じる
                await close(
                    .failed(Self.failureReason(error.localizedDescription, from: feed.kind)),
                    waitingForForwarding: false
                )
                return
            }
            guard isPreparing(run) else { return }
        }
        setState(.recording)
        restartCapturesInterruptedWhilePreparing()
        if let silenceTimeout {
            watchSilence(timeout: silenceTimeout, run: run)
        }
    }

    public func stop() async {
        // キャプチャストリームの正常終了（forwarding の完走）を待って、最後まで中継してから閉じる
        await close(.stopped, waitingForForwarding: true)
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
        /// 起動の途中（.preparing）に中断して、.recording に入るのを待っている再起動が連続何回目か
        var deferredRestartAttempt: Int?
        /// キャプチャの起動か再起動がそのキャプチャを受け持っている間 true。起動は start がスロットを作ってから、
        /// 再起動はキャプチャを止めるところから、どちらも中継を始めるか起動に失敗するまで続く。
        /// この間キャプチャを止めるのも起動するのも受け持った側だけで、閉じる側（stop() と失敗の片付け）は触れない。
        /// 実キャプチャは掴んでいるものを確かめてから解放するため、同じキャプチャへの呼び出しが重なると同じものを二重に解放する
        var isStartingCapture = true
    }

    /// 無音が続いたかを確かめる間隔。止まるのは無音が silenceTimeout に達してから最大でこの長さだけ遅れる。
    /// 分単位の silenceTimeout に対して十分短く、確かめるのは経過時間の比較だけなので負荷も無い
    private static let silenceCheckInterval: Duration = .seconds(15)

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
    /// この記録で保存できたセグメントの数。失敗で閉じたときに完了を知らせるかどうかを決める
    private var recordedSegmentCount = 0
    /// start ごとに振り直す記録の識別子。待ちから戻った start が、閉じられた後に始まった次の記録へ手を出さないようにする
    private var runID = UUID()
    /// この記録の保存先の確保。閉じる側は確保の途中なら終わるのを待ち、確保できていたときだけ閉じる
    private var storeBegin: Task<Void, any Error>?
    /// 無音の判定と、それを周期的に確かめる見張り。silenceTimeout を渡した記録の .recording の間だけある
    private var silenceMonitor: SilenceMonitor?
    private var silenceWatchdog: Task<Void, Never>?

    private var canStart: Bool {
        switch state {
        case .idle, .failed: true
        case .preparing, .recording, .stopping: false
        }
    }

    /// 記録が閉じられていない（準備中か記録中）
    private var isRunning: Bool {
        state == .preparing || state == .recording
    }

    /// 音源に由来する失敗の理由へ音源名を付ける（「マイク: …」）。
    /// 複数音源の記録では、ポップオーバーとログでどちらが止まったかを見分けられないため
    private static func failureReason(_ reason: String, from source: AudioSourceKind) -> String {
        "\(source.displayName): \(reason)"
    }

    private func setState(_ newState: SessionState) {
        state = newState
        eventContinuation.yield(.stateChanged(newState))
    }

    /// run の start がまだ続けてよいか。閉じられた後や、次の記録が始まった後は false
    private func isPreparing(_ run: UUID) -> Bool {
        runID == run && state == .preparing
    }

    /// エンジン起動 → スロット登録 → キャプチャ起動。スロットは capture.start の失敗時にも
    /// 積まれた状態で残し、呼び出し側の close で閉じさせる
    private func activate(
        feed: RecordingFeed,
        format: AVAudioFormat,
        context: TranscriptionContext,
        run: UUID
    ) async throws {
        let (chunkStream, chunkContinuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        let engineEvents = try await feed.engine.start(chunks: chunkStream, context: context)
        guard isPreparing(run) else {
            // エンジンを起動している間に閉じられた。閉じる側はスロットの無いこのエンジンを知らないため、ここで終わらせる。
            // キャプチャは起動しておらず音声が届いていないので、受け取る結果は無い
            chunkContinuation.finish()
            await feed.engine.finish()
            return
        }
        var slot = FeedSlot(feed: feed, format: format, chunkContinuation: chunkContinuation)
        slot.consumerTask = makeConsumerTask(engineEvents, slotID: slot.id, source: feed.kind)
        activeFeeds.append(slot)
        try await startCaptureAndForward(slotID: slot.id)
    }

    /// 停止と失敗で共通の閉じ方。キャプチャを止め、チャンク列を閉じ、エンジンに残りを吐き出させ、
    /// 結果を受けるタスクの保存を待ってからストアを閉じる。失敗でも記録できた分は保存してから閉じる。
    /// 片方の音源だけで録り続けると「揃った記録」に見えてしまうため、失敗は1つのフィードでも全体を閉じる。
    ///
    /// 最初に .stopping へ移った呼び出しだけが閉じる。後から来た停止や失敗は何もせずに戻り、終わり方は先に来た側で決まる。
    /// .stopping の後に終わったキャプチャのストリームは、中断として再起動されない。
    ///
    /// 起動や再起動の途中のキャプチャは、状態が変わったのを見た起動や再起動が止める。ここからも止めると同じキャプチャへの呼び出しが重なる。
    ///
    /// 失敗の片付けは、再起動を諦めたフィードの中継タスクや、失敗したエンジンの結果を受けるタスクの上で走る。
    /// 自分が走っているタスクの完走は待てない（待つと戻らない）ため、中継は待たず、結果を受けるタスクは自分のものを除いて待つ。
    /// 中継を待たないぶん、止める直前にキャプチャから届いていたチャンクはエンジンへ渡らないことがある
    ///
    /// 無音の見張りは取り消すだけで完走を待たない。取り消しで戻らない待ちもあり、戻った見張りは閉じた記録に何もしない。
    /// 無音での自動停止は見張りのタスクの上で閉じるため、見張りは閉じる前に自分を外し、ここから取り消されないようにしている
    private func close(
        _ reason: SessionEndReason,
        waitingForForwarding: Bool,
        runningOnConsumerOf currentSlotID: FeedSlot.ID? = nil
    ) async {
        guard isRunning else { return }
        setState(.stopping)
        silenceWatchdog?.cancel()
        silenceWatchdog = nil
        silenceMonitor = nil
        let slots = activeFeeds
        activeFeeds.removeAll()
        for slot in slots where !slot.isStartingCapture {
            await slot.feed.capture.stop()
        }
        if waitingForForwarding {
            // 再起動は forwarding の上で走るため、再起動がキャプチャを止め終えるのもここで一緒に待つ
            for slot in slots {
                await slot.forwardingTask?.value
            }
        }
        for slot in slots {
            slot.chunkContinuation?.finish()
        }
        for slot in slots {
            await slot.feed.engine.finish()
        }
        for slot in slots where slot.id != currentSlotID {
            await slot.consumerTask?.value
        }
        let ref = await finalizeStore(reason)
        switch reason {
        case .stopped, .autoStopped:
            if let ref {
                eventContinuation.yield(.sessionFinished(ref))
            }
            setState(.idle)
        case let .failed(message):
            // 記録できた分にはタイトル生成とプレイブックを走らせる。何も保存していない記録に走らせても必ず失敗する。
            // 状態は最後に failed にし、閉じた後もポップオーバーが失敗の理由を出し続けられるようにする
            if let ref, recordedSegmentCount > 0 {
                eventContinuation.yield(.sessionFinished(ref))
            }
            setState(.failed(message))
        }
    }

    /// 全 append 完了後に呼ぶ。保存先の確保の途中ならその終わりを待つ。
    /// 確保していない（できなかった）記録には閉じるものが無い
    private func finalizeStore(_ reason: SessionEndReason) async -> SessionRef? {
        guard let storeBegin, case .success = await storeBegin.result else { return nil }
        // finalize 失敗は記録済みデータに影響しないため握る
        return try? await store.finalize(endedAt: now(), reason: reason)
    }

    private func activeIndex(of slotID: FeedSlot.ID) -> Int? {
        activeFeeds.firstIndex { $0.id == slotID }
    }

    /// スロットのキャプチャを起動し、チャンクをそのフィードのエンジンへ中継する。
    /// 起動を待つ間に停止や失敗の片付けでスロットが外れていたら、起動したキャプチャを止めて中継しない。
    /// 閉じる側は起動の途中のキャプチャに触れないため、止めないと誰も止めないキャプチャがデバイスを掴んだまま残る
    private func startCaptureAndForward(slotID: FeedSlot.ID) async throws {
        guard let index = activeIndex(of: slotID) else { return }
        let slot = activeFeeds[index]
        let stream: AsyncThrowingStream<AudioChunk, any Error>
        do {
            stream = try await slot.feed.capture.start(targetFormat: slot.format)
        } catch {
            // 起動できなかったキャプチャも、掴みかけたものを放すため止める。記録が続いていれば受け持ちを戻し、
            // 止めるのは失敗の片付けか再起動のやり直しに任せる。閉じられた後なら止める側がいないので、ここで止める
            if isRunning, let index = activeIndex(of: slotID) {
                activeFeeds[index].isStartingCapture = false
            } else {
                await slot.feed.capture.stop()
            }
            throw error
        }
        guard isRunning,
              let index = activeIndex(of: slotID),
              let chunkContinuation = slot.chunkContinuation
        else {
            await slot.feed.capture.stop()
            return
        }
        // 中継を始めたキャプチャは、再起動したものも stop() と失敗の片付けが止める。
        // 中継の開始と同じ区切りで受け持ちを戻し、止める側がいないキャプチャを作らない
        activeFeeds[index].isStartingCapture = false
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
        // 閉じている途中（.stopping）や閉じた後に届く終了は、閉じる側が止めたキャプチャのもので中断ではない。
        // スロットが無いのは、前回の記録のキャプチャの終了が届いたとき。どちらも何もしない
        guard isRunning, let index = activeIndex(of: slotID) else { return }
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
        guard state == .recording else {
            // 起動の途中（.preparing）の中断は、.recording に入ってから再起動する。start が他のキャプチャを
            // 起動している間に止めたり起動したりすると、その起動を乱しかねない。起動の失敗は再起動されず、記録全体の失敗になる
            activeFeeds[index].deferredRestartAttempt = attempt
            return
        }
        await restartCapture(slotID: slotID, attempt: attempt)
    }

    /// 中断したキャプチャを止め、落ち着くのを待ってから起動し直す。attempt は連続何回目の再起動か
    private func restartCapture(slotID: FeedSlot.ID, attempt: Int) async {
        guard state == .recording, let index = activeIndex(of: slotID) else { return }
        let capture = activeFeeds[index].feed.capture
        // ここから中継を再開するまで、このキャプチャへの呼び出しは再起動だけが行う。
        // 止まったキャプチャが掴んでいるものを、待つ間も持ち続けないよう先に止める。
        // 1回の構成変更で中断の通知は続けて届くため、落ち着くのを待ってから再起動する
        activeFeeds[index].isStartingCapture = true
        await capture.stop()
        // 待ちが途中で投げても握る。再起動するかどうかは、続く確認で記録がまだ続いているかを見て決める
        try? await sleep(restartPolicy.settleDelay)
        // actor は再入するため、待つ間に stop や失敗の片付けが走り、次の記録が始まっていることもある
        guard state == .recording, let index = activeIndex(of: slotID) else { return }
        // 時刻は起動の直前に取る。数え直しは、再起動してから動いた時間で決めるため
        activeFeeds[index].consecutiveRestarts = attempt
        activeFeeds[index].lastRestartAt = now()
        do {
            try await startCaptureAndForward(slotID: slotID)
        } catch {
            // 起動できなかったのも連続した中断の1回として数え、同じ手順でやり直すか諦める。
            // 起動を待つ間（許可の確認など）に stableInterval が過ぎても数え直さないよう、時刻は失敗した時点に取り直す
            if let index = activeIndex(of: slotID) {
                activeFeeds[index].lastRestartAt = now()
            }
            await attemptCaptureRestart(slotID: slotID, reason: error.localizedDescription)
        }
    }

    /// 起動の途中に中断したキャプチャを、.recording に入ったところで再起動する。
    /// そのフィードの中継は中断で終わっているため、再起動をそのスロットの中継タスクとして走らせ、stop() が完走を待てるようにする
    private func restartCapturesInterruptedWhilePreparing() {
        for index in activeFeeds.indices {
            guard let attempt = activeFeeds[index].deferredRestartAttempt else { continue }
            activeFeeds[index].deferredRestartAttempt = nil
            let slotID = activeFeeds[index].id
            activeFeeds[index].forwardingTask = Task { [weak self] in
                await self?.restartCapture(slotID: slotID, attempt: attempt)
            }
        }
    }

    /// 失敗したフィードの中継タスクの上で走る
    private func giveUpCapture(source: AudioSourceKind, reason: String) async {
        eventContinuation.yield(.captureInterrupted(CaptureInterruption(
            source: source, reason: reason, restartAttempt: nil
        )))
        await close(.failed(Self.failureReason(reason, from: source)), waitingForForwarding: false)
    }

    private func makeConsumerTask(
        _ engineEvents: AsyncThrowingStream<TranscriptEvent, any Error>,
        slotID: FeedSlot.ID,
        source: AudioSourceKind
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await event in engineEvents {
                    await self?.handle(event)
                }
            } catch {
                await self?.engineFailed(error, slotID: slotID, source: source)
            }
        }
    }

    private func handle(_ event: TranscriptEvent) async {
        switch event {
        case let .volatile(text):
            noteSpeech(text)
            eventContinuation.yield(.liveTranscript(text))
        case let .finalized(segment):
            // 届いた時点で数え直す。翻訳を待つ間（最大 translationTimeout）を無音に数えない
            noteSpeech(segment.text)
            let segment = await translated(segment)
            do {
                try await store.append(segment)
                recordedSegmentCount += 1
                eventContinuation.yield(.segmentRecorded(segment))
            } catch {
                // 保存失敗でセッションは止めない。UI へ通知して継続する
                eventContinuation.yield(.storeError(error.localizedDescription))
            }
        }
    }

    /// 無音を見張っている記録なら、発話とみなせる結果が届いた時刻から無音を数え直す
    private func noteSpeech(_ text: String) {
        silenceMonitor?.recordActivity(text, at: now())
    }

    /// 無音が timeout 続いたら閉じる見張りを始める。確かめる間隔は silenceCheckInterval で、
    /// timeout がそれより短ければ timeout ごとに確かめる（間隔ごとでは timeout の何倍も遅れて止まる）
    private func watchSilence(timeout: Duration, run: UUID) {
        silenceMonitor = SilenceMonitor(timeout: timeout, startedAt: now())
        let interval = min(Self.silenceCheckInterval, timeout)
        silenceWatchdog = Task { [weak self, sleep] in
            repeat {
                // 取り消されたら抜ける（停止と失敗で閉じたとき）
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
            } while await self?.checkSilence(run: run) == true
        }
    }

    /// 見張りの1回ぶんの確認。見張りを続けるなら true を返す。
    /// 閉じた記録や、閉じた後に始まった次の記録には何もしない。取り消しでは戻らない待ちもあるため
    private func checkSilence(run: UUID) async -> Bool {
        guard runID == run, state == .recording, let monitor = silenceMonitor else { return false }
        guard monitor.isExpired(at: now()) else { return true }
        // 閉じるのはこの見張りのタスクの上で行う。close が見張りを取り消すと、取り消されたタスクで engine.finish が走り、
        // SpeechAnalyzer の finalize が CancellationError で抜けて残りの結果を落とす。
        // 取り消されないよう、閉じる前に自分を外す
        silenceWatchdog = nil
        eventContinuation.yield(.autoStopped(silence: monitor.timeout))
        await close(.autoStopped, waitingForForwarding: true)
        return false
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

    /// 失敗したエンジンの結果を受けるタスクの上で走る。閉じるときにそのタスクの完走は待たない。
    /// 起動の途中の失敗も、起動に失敗したのと同じく記録全体を閉じる。エンジンの失敗は再起動では直らない
    private func engineFailed(_ error: any Error, slotID: FeedSlot.ID, source: AudioSourceKind) async {
        // スロットが無いのは、閉じる側が外した後のエンジンの終了。失敗ではない
        guard isRunning, activeIndex(of: slotID) != nil else { return }
        await close(
            .failed(Self.failureReason(error.localizedDescription, from: source)),
            waitingForForwarding: false,
            runningOnConsumerOf: slotID
        )
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
