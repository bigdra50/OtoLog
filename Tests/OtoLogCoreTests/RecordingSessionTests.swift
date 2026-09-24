@preconcurrency import AVFAudio
import Foundation
@testable import OtoLogCore
import Testing

struct RecordingSessionTests {
    // MARK: Internal

    struct Boom: Error {}

    /// 理由の文言まで検証するためのエラー。localizedDescription が message になる
    struct Described: LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    @Test func startEmitsPreparingProgressThenRecording() async {
        let sut = makeSUT()
        sut.engine.progressScript = [0.5]

        await sut.session.start(feeds: sut.feeds, locales: [ja])

        #expect(await eventually { sut.collector.events.contains(.stateChanged(.recording)) })
        #expect(Array(sut.collector.events.prefix(3)) == [
            .stateChanged(.preparing),
            .preparationProgress(0.5),
            .stateChanged(.recording),
        ])
        #expect(sut.engine.prepareCallCount == 1)
        #expect(sut.capture.receivedTargetFormats.first?.sampleRate == 16000)
    }

    /// セッション識別子の発行はセッションの責務。engine には context として渡る
    @Test func startPassesContextWithInjectedIdentityToEngine() async throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000A"))
        let startedAt = Date(timeIntervalSince1970: 1_785_297_600)
        let sut = makeSUT(now: { startedAt }, makeSessionID: { id })

        await sut.session.start(feeds: sut.feeds, locales: [ja])

        _ = await eventually { await sut.session.state == .recording }
        let context = sut.engine.receivedContexts.first
        #expect(context?.sessionID == id)
        #expect(context?.sessionStartedAt == startedAt)
        #expect(context?.locale == "ja-JP")
        #expect(context?.source == .system)
        // store にも同じ context が配られ、保存先の確保（begin）が先行する
        #expect(await sut.store.beganContexts.first == context)
    }

    @Test func finalizedEventsAreStoredAndReported() async {
        let sut = await makeStartedSUT()
        let segment = TestFixtures.segment(text: "確定")

        sut.engine.send(.finalized(segment))

        #expect(await eventually { await sut.store.segments == [segment] })
        #expect(await eventually { sut.collector.events.contains(.segmentRecorded(segment)) })
    }

    @Test func volatileEventsBypassStore() async {
        let sut = await makeStartedSUT()

        sut.engine.send(.volatile("ライブ"))

        #expect(await eventually { sut.collector.events.contains(.liveTranscript("ライブ")) })
        #expect(await sut.store.segments.isEmpty)
    }

    @Test func stopStopsCaptureThenFinishesEngineThenFinalizesStore() async {
        let sut = await makeStartedSUT()
        let order = OrderLog()
        sut.capture.onStop = { order.append("capture.stop") }
        sut.engine.onFinish = { order.append("engine.finish") }
        await sut.store.setOnFinalize { order.append("store.finalize") }

        await sut.session.stop()

        #expect(order.entries == ["capture.stop", "engine.finish", "store.finalize"])
        #expect(await sut.session.state == .idle)
        #expect(sut.collector.events.contains(.stateChanged(.stopping)))
        #expect(await eventually { sut.collector.events.contains(.stateChanged(.idle)) })
    }

    /// 停止完了時にセッション参照を通知する（タイトル生成やパイプラインの起点）
    @Test func stopEmitsSessionFinishedWithStoreRef() async {
        let endedAt = Date(timeIntervalSince1970: 1_785_301_200)
        let sut = await makeStartedSUT(now: { endedAt })
        let ref = SessionRef(
            directoryName: "2026-07-29_1300", title: nil,
            startedAt: Date(timeIntervalSince1970: 1_785_297_600)
        )
        await sut.store.setFinalizeResult(ref)

        await sut.session.stop()

        #expect(await eventually { sut.collector.events.contains(.sessionFinished(ref)) })
        #expect(await sut.store.finalizedAts == [endedAt])
        #expect(await sut.store.finalizedReasons == [.stopped])
    }

    @Test func stopWhenIdleDoesNotFinalize() async {
        let sut = makeSUT()

        await sut.session.stop()

        #expect(await sut.store.finalizedAts.isEmpty)
    }

    @Test func secondStartWhileRecordingIsNoOp() async {
        let sut = await makeStartedSUT()

        await sut.session.start(feeds: sut.feeds, locales: [ja])

        #expect(sut.engine.prepareCallCount == 1)
    }

    @Test func stopWhenIdleIsNoOp() async {
        let sut = makeSUT()

        await sut.session.stop()

        #expect(sut.capture.stopCallCount == 0)
        #expect(await sut.session.state == .idle)
    }

    @Test func prepareFailureLeadsToFailedWithoutStartingCapture() async {
        let sut = makeSUT()
        sut.engine.prepareError = Boom()

        await sut.session.start(feeds: sut.feeds, locales: [ja])

        let state = await sut.session.state
        guard case .failed = state else {
            Issue.record("failed ではなかった: \(state)")
            return
        }
        #expect(sut.capture.startCallCount == 0)
    }

    @Test func captureFailureTriggersSingleRestartAndPipelineSurvives() async {
        let sut = await makeStartedSUT()

        sut.capture.fail(Boom())

        #expect(await eventually { sut.capture.startCallCount == 2 })
        #expect(await sut.session.state == .recording)

        sut.capture.emit(AudioChunk(buffer: TestSignal.sine(format: sut.engine.prepareFormat, seconds: 0.1)))
        #expect(await eventually { sut.engine.consumedChunkCount == 1 })
    }

    @Test func storeErrorKeepsSessionRecording() async {
        struct DiskFull: Error {}
        let sut = await makeStartedSUT()

        await sut.store.setError(DiskFull())
        sut.engine.send(.finalized(TestFixtures.segment(text: "失敗する")))
        #expect(await eventually {
            sut.collector.events.contains { if case .storeError = $0 { true } else { false } }
        })
        #expect(await sut.session.state == .recording)

        await sut.store.setError(nil)
        let recovered = TestFixtures.segment(text: "復帰後")
        sut.engine.send(.finalized(recovered))
        #expect(await eventually { await sut.store.segments == [recovered] })
    }

    // MARK: 複数入力（システム音声 + マイク）

    /// フィードごとにキャプチャとエンジンを対で起動する
    @Test func startWithTwoFeedsStartsBothPairs() async {
        let sut = makeSUT(kinds: [.system, .microphone])

        await sut.session.start(feeds: sut.feeds, locales: [ja])

        #expect(await eventually { await sut.session.state == .recording })
        for feed in sut.feedDoubles {
            #expect(feed.engine.prepareCallCount == 1)
            #expect(feed.capture.startCallCount == 1)
        }
    }

    /// セグメントの話者区別の根拠になる source は、フィードの種別ごとに context へ入る。
    /// セッション識別子は全フィードで共有される（同じ記録の別音源）
    @Test func contextSourceMatchesFeedKind() async throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000B"))
        let sut = makeSUT(kinds: [.system, .microphone], makeSessionID: { id })

        await sut.session.start(feeds: sut.feeds, locales: [ja])

        _ = await eventually { await sut.session.state == .recording }
        #expect(sut.feedDoubles[0].engine.receivedContexts.first?.source == .system)
        #expect(sut.feedDoubles[1].engine.receivedContexts.first?.source == .microphone)
        #expect(sut.feedDoubles[1].engine.receivedContexts.first?.sessionID == id)
    }

    /// 保存先の確保はセッションに1回。meta の source は先頭フィードを代表にする
    @Test func beginIsCalledOncePerSession() async {
        let sut = makeSUT(kinds: [.system, .microphone])

        await sut.session.start(feeds: sut.feeds, locales: [ja])

        _ = await eventually { await sut.session.state == .recording }
        #expect(await sut.store.beganContexts.count == 1)
        #expect(await sut.store.beganContexts.first?.source == .system)
    }

    @Test func microphoneOnlyFeedBeginsStoreWithMicrophoneSource() async {
        let sut = makeSUT(kinds: [.microphone])

        await sut.session.start(feeds: sut.feeds, locales: [ja])

        _ = await eventually { await sut.session.state == .recording }
        #expect(await sut.store.beganContexts.first?.source == .microphone)
    }

    /// 両方の音源の確定セグメントが同じストアへ集まる（時系列マージは読み手側の責務）
    @Test func segmentsFromAllFeedsAreStored() async {
        let sut = await makeStartedSUT(kinds: [.system, .microphone])
        let fromSystem = TestFixtures.segment(text: "相手の発言", source: .system)
        let fromMicrophone = TestFixtures.segment(text: "自分の発言", source: .microphone)

        sut.feedDoubles[0].engine.send(.finalized(fromSystem))
        sut.feedDoubles[1].engine.send(.finalized(fromMicrophone))

        #expect(await eventually { await sut.store.segments.count == 2 })
        #expect(await sut.store.segments.contains(fromSystem))
        #expect(await sut.store.segments.contains(fromMicrophone))
    }

    /// キャプチャはエンジンごとに用意されたフォーマットで始める（フィード間で共有しない）
    @Test func eachCaptureReceivesItsOwnEngineFormat() async throws {
        let sut = makeSUT(kinds: [.system, .microphone])
        sut.feedDoubles[1].engine.prepareFormat = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 24000, channels: 1
        ))

        await sut.session.start(feeds: sut.feeds, locales: [ja])

        _ = await eventually { await sut.session.state == .recording }
        #expect(sut.feedDoubles[0].capture.receivedTargetFormats.first?.sampleRate == 16000)
        #expect(sut.feedDoubles[1].capture.receivedTargetFormats.first?.sampleRate == 24000)
    }

    /// 停止は全キャプチャ → 全エンジン → ストア確定の順。確定は1回だけ
    @Test func stopStopsAllFeedsBeforeFinalizingOnce() async {
        let sut = await makeStartedSUT(kinds: [.system, .microphone])
        let order = OrderLog()
        sut.feedDoubles[0].capture.onStop = { order.append("capture.stop[system]") }
        sut.feedDoubles[1].capture.onStop = { order.append("capture.stop[mic]") }
        sut.feedDoubles[0].engine.onFinish = { order.append("engine.finish[system]") }
        sut.feedDoubles[1].engine.onFinish = { order.append("engine.finish[mic]") }
        await sut.store.setOnFinalize { order.append("store.finalize") }

        await sut.session.stop()

        #expect(order.entries == [
            "capture.stop[system]",
            "capture.stop[mic]",
            "engine.finish[system]",
            "engine.finish[mic]",
            "store.finalize",
        ])
        #expect(await sut.store.finalizedAts.count == 1)
    }

    /// 片方の音源の一過性障害では、そのフィードだけを再起動して記録を続ける
    @Test func oneFeedFailureRestartsOnlyThatFeed() async {
        let sut = await makeStartedSUT(kinds: [.system, .microphone])

        sut.feedDoubles[1].capture.fail(Boom())

        #expect(await eventually { sut.feedDoubles[1].capture.startCallCount == 2 })
        #expect(sut.feedDoubles[0].capture.startCallCount == 1)
        #expect(await sut.session.state == .recording)
    }

    /// 起動途中の失敗はセッション全体を failed にし、起動済みのキャプチャを畳む
    @Test func startFailureOnAnyFeedFailsSessionAndStopsStartedCaptures() async {
        let sut = makeSUT(kinds: [.system, .microphone])
        sut.feedDoubles[1].capture.errorOnStart = Boom()

        await sut.session.start(feeds: sut.feeds, locales: [ja])

        #expect(await eventually {
            if case .failed = await sut.session.state { return true }
            return false
        })
        #expect(await eventually { sut.feedDoubles[0].capture.stopCallCount == 1 })
    }

    /// 失敗で畳むときに止めた側のキャプチャの終了は中断ではない。再起動も中断の通知もしない
    @Test func tearDownAfterFailureDoesNotRestartTheOtherFeed() async {
        let sut = await makeStartedSUT(kinds: [.system, .microphone], restartPolicy: singleRestart)
        sut.feedDoubles[1].capture.fail(Described(message: "1回目"))
        #expect(await eventually { sut.feedDoubles[1].capture.startCallCount == 2 })

        sut.feedDoubles[1].capture.fail(Described(message: "2回目"))

        #expect(await eventually { sut.feedDoubles[0].capture.stopCallCount == 1 })
        #expect(await eventually { await sut.session.state == .failed("マイク: 2回目") })
        #expect(sut.feedDoubles[0].capture.startCallCount == 1)
        #expect(!sut.collector.events.contains {
            if case let .captureInterrupted(interruption) = $0 { interruption.source == .system } else { false }
        })
    }

    // MARK: 中断と失敗理由（どの音源か）

    /// 再起動で続く中断も、どの音源がなぜ止まったかを流す。後から経緯を追えるようにするため
    @Test func captureFailureReportsInterruptionWithFirstRestartAttempt() async {
        let sut = await makeStartedSUT(kinds: [.system, .microphone])

        sut.feedDoubles[1].capture.fail(Described(message: "デバイスが外れた"))

        #expect(await eventually {
            sut.collector.events.contains(.captureInterrupted(CaptureInterruption(
                source: .microphone, reason: "デバイスが外れた", restartAttempt: 1
            )))
        })
        #expect(await eventually { sut.feedDoubles[1].capture.startCallCount == 2 })
        #expect(await sut.session.state == .recording)
    }

    /// 再起動を諦めるときは restartAttempt なしで流し、続く failed の理由には音源名を付ける
    @Test func interruptionBeyondRestartLimitReportsGiveUpAndNamesTheFeed() async throws {
        let sut = await makeStartedSUT(kinds: [.system, .microphone], restartPolicy: singleRestart)
        sut.feedDoubles[1].capture.fail(Described(message: "1回目"))
        #expect(await eventually { sut.feedDoubles[1].capture.startCallCount == 2 })

        sut.feedDoubles[1].capture.fail(Described(message: "2回目"))

        let failed = SessionEvent.stateChanged(.failed("マイク: 2回目"))
        #expect(await eventually { sut.collector.events.contains(failed) })
        let events = sut.collector.events
        let giveUpIndex = try #require(events.firstIndex(of: .captureInterrupted(CaptureInterruption(
            source: .microphone, reason: "2回目", restartAttempt: nil
        ))))
        let failedIndex = try #require(events.firstIndex(of: failed))
        #expect(giveUpIndex < failedIndex)
    }

    /// 停止に伴うキャプチャの終了は中断ではない
    @Test func stopDoesNotReportCaptureInterruption() async {
        let sut = await makeStartedSUT(kinds: [.system, .microphone])

        await sut.session.stop()

        #expect(await eventually { sut.collector.events.contains(.stateChanged(.idle)) })
        #expect(!sut.collector.events.contains { if case .captureInterrupted = $0 { true } else { false } })
    }

    /// 認識エンジンの異常終了も、どの音源のエンジンかを理由に付ける
    @Test func engineFailureNamesTheFeed() async {
        let sut = await makeStartedSUT(kinds: [.system, .microphone])

        sut.feedDoubles[0].engine.failEvents(Described(message: "認識が止まった"))

        #expect(await eventually { await sut.session.state == .failed("システム音声: 認識が止まった") })
    }

    @Test func prepareFailureNamesTheFeed() async {
        let sut = makeSUT(kinds: [.system, .microphone])
        sut.feedDoubles[1].engine.prepareError = Described(message: "モデルが無い")

        await sut.session.start(feeds: sut.feeds, locales: [ja])

        #expect(await sut.session.state == .failed("マイク: モデルが無い"))
    }

    @Test func captureStartFailureNamesTheFeed() async {
        let sut = makeSUT(kinds: [.system, .microphone])
        sut.feedDoubles[1].capture.errorOnStart = Described(message: "許可が無い")

        await sut.session.start(feeds: sut.feeds, locales: [ja])

        #expect(await sut.session.state == .failed("マイク: 許可が無い"))
    }

    /// 保存先の確保は音源に依らないため、音源名を付けない
    @Test func storeBeginFailureIsNotAttributedToAFeed() async {
        let sut = makeSUT(kinds: [.system, .microphone])
        await sut.store.setBeginError(Described(message: "保存先に書けない"))

        await sut.session.start(feeds: sut.feeds, locales: [ja])

        #expect(await sut.session.state == .failed("保存先に書けない"))
    }

    // MARK: 再起動の方針（連続した中断の数え方と手順）

    /// 長時間の記録では中断が時間をおいて何度も起きる。間に stableInterval 以上動いていれば、
    /// 何度目の中断でも1回目として再起動し、記録を続ける
    @Test func interruptionsSpacedBeyondStableIntervalNeverFailTheSession() async {
        let clock = TestClock()
        let sut = await makeStartedSUT(now: { clock.now })

        for count in 1...5 {
            sut.capture.fail(Described(message: "\(count)回目"))
            #expect(await eventually { sut.capture.startCallCount == count + 1 })
            clock.advance(by: CaptureRestartPolicy.default.stableInterval)
        }

        #expect(await eventually { restartAttempts(in: sut.collector.events) == [1, 1, 1, 1, 1] })
        #expect(await sut.session.state == .recording)
    }

    /// 立て続けの中断は連続として数え、上限を超えたら諦める
    @Test func consecutiveInterruptionsFailAfterMaxRestarts() async {
        let clock = TestClock()
        let sut = await makeStartedSUT(now: { clock.now })

        for count in 1...3 {
            sut.capture.fail(Described(message: "\(count)回目"))
            #expect(await eventually { sut.capture.startCallCount == count + 1 })
        }
        sut.capture.fail(Described(message: "4回目"))

        #expect(await eventually { await sut.session.state == .failed("システム音声: 4回目") })
        #expect(await eventually { restartAttempts(in: sut.collector.events) == [1, 2, 3, nil] })
        #expect(sut.capture.startCallCount == 4)
    }

    /// 数え直すかどうかは最後の再起動から測る。stableInterval に満たない間隔で中断が続けば、
    /// 最初の再起動からは stableInterval を超えていても連続として数え、上限を超えたら諦める
    @Test func stableIntervalIsMeasuredFromTheLatestRestart() async {
        let clock = TestClock()
        let sut = await makeStartedSUT(now: { clock.now })
        let shortOfStable = CaptureRestartPolicy.default.stableInterval - .seconds(1)

        for count in 1...3 {
            clock.advance(by: shortOfStable)
            sut.capture.fail(Described(message: "\(count)回目"))
            #expect(await eventually { sut.capture.startCallCount == count + 1 })
        }
        clock.advance(by: shortOfStable)
        sut.capture.fail(Described(message: "4回目"))

        #expect(await eventually { await sut.session.state == .failed("システム音声: 4回目") })
        #expect(await eventually { restartAttempts(in: sut.collector.events) == [1, 2, 3, nil] })
    }

    /// 止めずに起動し直すと前回のタップやエンジンが残る。止めて、待ってから起動する
    @Test func restartStopsTheCaptureAndSettlesBeforeStartingItAgain() async {
        let order = OrderLog()
        let sleep = ManualSleep()
        let sut = await makeStartedSUT(sleep: { duration in
            order.append("sleep")
            await sleep.sleep(for: duration)
        })
        sut.capture.onStop = { order.append("capture.stop") }
        sut.capture.onStart = { order.append("capture.start") }

        sut.capture.fail(Boom())

        #expect(await eventually { sut.capture.startCallCount == 2 })
        #expect(order.entries == ["capture.stop", "sleep", "capture.start"])
        #expect(sleep.requestedDurations == [CaptureRestartPolicy.default.settleDelay])
    }

    /// 待つ間に停止されたら再起動しない。記録は失敗扱いにせず、そのまま閉じる
    @Test func stopDuringSettleDelayFinishesWithoutRestarting() async {
        let sleep = ManualSleep(holding: true)
        let sut = await makeStartedSUT(sleep: { await sleep.sleep(for: $0) })
        sut.capture.fail(Boom())
        #expect(await eventually { sleep.waitingCount == 1 })

        // 停止は待っている再起動が抜けるのを待つため、別タスクで始めてから待ちを解く
        let stopping = Task { await sut.session.stop() }
        #expect(await eventually { await sut.session.state == .stopping })
        sleep.release()
        await stopping.value

        #expect(await sut.session.state == .idle)
        #expect(sut.capture.startCallCount == 1)
        #expect(await sut.store.finalizedAts.count == 1)
        #expect(await eventually {
            sut.collector.events.contains { if case .sessionFinished = $0 { true } else { false } }
        })
        #expect(!sut.collector.events.contains { if case .stateChanged(.failed) = $0 { true } else { false } })
    }

    /// 再起動の start を待つ間に停止されたら、起動し終えたキャプチャを止めてから抜ける。
    /// 中継しないキャプチャが動き続けると、記録を止めた後もデバイスを掴んだまま残る。
    /// 停止の側からは、起動の途中のキャプチャに stop を重ねない
    @Test func stopWhileRestartedCaptureIsStartingLeavesNoCaptureRunning() async {
        let gate = ManualSleep(holding: true)
        let sut = await makeStartedSUT()
        sut.capture.onStart = { await gate.sleep(for: .zero) }
        sut.capture.fail(Boom())
        #expect(await eventually { gate.waitingCount == 1 })

        let stopping = Task { await sut.session.stop() }
        #expect(await eventually { await sut.session.state == .stopping })
        gate.release()
        await stopping.value

        #expect(await sut.session.state == .idle)
        #expect(sut.capture.startCallCount == 2)
        #expect(!sut.capture.isCapturing)
        // stop は再起動の2回だけ（待つ前と、起動し終えた後）
        #expect(sut.capture.stopCallCount == 2)
        #expect(sut.capture.maxConcurrentCalls == 1)
    }

    /// 再起動がキャプチャを止めている最中に停止されたら、そのキャプチャを止めるのは再起動に任せる。
    /// 同じキャプチャの stop を重ねると、実キャプチャは掴んでいるものを確かめてから解放するため、同じものを二重に解放する
    @Test func stopWhileRestartIsStoppingTheCaptureDoesNotStopItAgain() async {
        let gate = ManualSleep(holding: true)
        let sut = await makeStartedSUT()
        sut.capture.onStop = { await gate.sleep(for: .zero) }
        sut.capture.fail(Boom())
        #expect(await eventually { gate.waitingCount == 1 })

        let stopping = Task { await sut.session.stop() }
        #expect(await eventually { await sut.session.state == .stopping })
        gate.release()
        await stopping.value

        #expect(await sut.session.state == .idle)
        #expect(sut.capture.stopCallCount == 1)
        #expect(sut.capture.maxConcurrentCalls == 1)
        #expect(sut.capture.startCallCount == 1)
    }

    /// 再起動がキャプチャを止めている最中に他の音源の失敗で畳まれても、そのキャプチャに stop を重ねない。
    /// 畳む側は再起動の stop を待たずに failed にし、止め終えるのは再起動に任せる
    @Test func failureWhileRestartIsStoppingTheCaptureDoesNotStopItAgain() async {
        let gate = ManualSleep(holding: true)
        let sut = await makeStartedSUT(kinds: [.system, .microphone])
        let microphone = sut.feedDoubles[1].capture
        microphone.onStop = { await gate.sleep(for: .zero) }
        microphone.fail(Boom())
        #expect(await eventually { gate.waitingCount == 1 })

        sut.feedDoubles[0].engine.failEvents(Described(message: "認識が止まった"))

        #expect(await eventually { await sut.session.state == .failed("システム音声: 認識が止まった") })
        gate.release()
        #expect(await eventually { gate.returnedCount == 1 })
        #expect(microphone.stopCallCount == 1)
        #expect(microphone.maxConcurrentCalls == 1)
        #expect(sut.feedDoubles[0].capture.stopCallCount == 1)
    }

    /// 中継を再開したキャプチャは、以降の停止で他と同じく止まる。
    /// 再起動の受け持ちが残ると停止はそのキャプチャを止めず、終わらない中継を待ち続ける
    @Test func stopAfterARestartStopsTheRestartedCapture() async {
        let sut = await makeStartedSUT()
        sut.capture.fail(Boom())
        #expect(await eventually { sut.capture.startCallCount == 2 })
        sut.capture.emit(AudioChunk(buffer: TestSignal.sine(format: sut.engine.prepareFormat, seconds: 0.1)))
        #expect(await eventually { sut.engine.consumedChunkCount == 1 })

        // 停止が戻らない場合もテストが終わるよう、別タスクで始めて状態を待つ
        Task { await sut.session.stop() }

        #expect(await eventually { await sut.session.state == .idle })
        #expect(!sut.capture.isCapturing)
    }

    /// 中継を再開したキャプチャは、次の中断で諦めて畳むときにも止まる
    @Test func givingUpAfterARestartStopsTheRestartedCapture() async {
        let sut = await makeStartedSUT(restartPolicy: singleRestart)
        sut.capture.fail(Described(message: "1回目"))
        #expect(await eventually { sut.capture.startCallCount == 2 })

        sut.capture.fail(Described(message: "2回目"))

        #expect(await eventually { await sut.session.state == .failed("システム音声: 2回目") })
        #expect(!sut.capture.isCapturing)
    }

    /// 待つ間に記録が失敗で畳まれ、次の記録が始まっていたら、古い再起動は新しい記録のキャプチャに触れない
    @Test func restartSkipsWhenANewerSessionStartedDuringSettleDelay() async {
        let sleep = ManualSleep(holding: true)
        let sut = await makeStartedSUT(sleep: { await sleep.sleep(for: $0) })
        sut.capture.fail(Described(message: "止まった"))
        #expect(await eventually { sleep.waitingCount == 1 })
        sut.engine.failEvents(Described(message: "認識が止まった"))
        #expect(await eventually { await sut.session.state == .failed("システム音声: 認識が止まった") })
        let next = FeedDoubles(capture: FakeCaptureSource(), engine: FakeTranscriptionEngine(), kind: .system)
        await sut.session.start(feeds: [next.feed], locales: [ja])
        #expect(await sut.session.state == .recording)

        sleep.release()

        // 待ち明けの確認は actor 上で終わり、外からその終わりを待つ手段は無い。待ちから戻ったのを見てから確かめる。
        // 正しく抜けていれば、確かめる時期によらず何も起きていない
        #expect(await eventually { sleep.returnedCount == 1 })
        #expect(await sut.session.state == .recording)
        #expect(next.capture.startCallCount == 1)
        #expect(sut.capture.startCallCount == 1)
    }

    /// 再起動の start が投げたら、それも連続した中断の1回として数え、同じ手順（止める → 待つ → 起動する）でやり直す
    @Test func restartWhoseStartThrowsCountsAsNextConsecutiveInterruption() async {
        let order = OrderLog()
        let sut = await makeStartedSUT(sleep: { _ in order.append("sleep") })
        sut.capture.onStop = { order.append("capture.stop") }
        sut.capture.onStart = { order.append("capture.start") }
        sut.capture.startErrors = [Described(message: "起動できない")]

        sut.capture.fail(Described(message: "止まった"))

        #expect(await eventually { sut.capture.startCallCount == 3 })
        #expect(await sut.session.state == .recording)
        #expect(order.entries == [
            "capture.stop", "sleep", "capture.start",
            "capture.stop", "sleep", "capture.start",
        ])
        #expect(await eventually {
            interruptions(in: sut.collector.events) == [
                CaptureInterruption(source: .system, reason: "止まった", restartAttempt: 1),
                CaptureInterruption(source: .system, reason: "起動できない", restartAttempt: 2),
            ]
        })
    }

    /// 再起動できないまま上限に達したら、最後の起動エラーを理由に諦める
    @Test func restartsThatKeepFailingToStartGiveUpWithTheStartError() async {
        var policy = CaptureRestartPolicy.default
        policy.maxConsecutiveRestarts = 2
        let sut = await makeStartedSUT(restartPolicy: policy)
        sut.capture.errorOnStart = Described(message: "起動できない")

        sut.capture.fail(Described(message: "止まった"))

        #expect(await eventually { await sut.session.state == .failed("システム音声: 起動できない") })
        #expect(await eventually {
            interruptions(in: sut.collector.events) == [
                CaptureInterruption(source: .system, reason: "止まった", restartAttempt: 1),
                CaptureInterruption(source: .system, reason: "起動できない", restartAttempt: 2),
                CaptureInterruption(source: .system, reason: "起動できない", restartAttempt: nil),
            ]
        })
        #expect(sut.capture.startCallCount == 3)
        // 再起動ごとに止める2回と、諦めて畳むときの1回。起動できなかったキャプチャも畳むときに止める
        #expect(sut.capture.stopCallCount == 3)
    }

    /// 起動に stableInterval 以上かかってから投げても（許可の確認待ちなど）、連続した中断の1回として数える。
    /// 起動を待った時間を動いた時間に数えると、起動できないまま1回目の再起動を繰り返して諦めない
    @Test func restartWhoseStartThrowsAfterStableIntervalStillCountsAsConsecutive() async {
        let clock = TestClock()
        let policy = CaptureRestartPolicy.default
        let sut = await makeStartedSUT(now: { clock.now })
        sut.capture.onStart = { clock.advance(by: policy.stableInterval) }
        // 数え直してしまう場合もテストが終わるよう、投げるのは上限の回数に限る
        sut.capture.startErrors = Array(
            repeating: Described(message: "起動できない"), count: policy.maxConsecutiveRestarts
        )

        sut.capture.fail(Described(message: "止まった"))

        #expect(await eventually { await sut.session.state == .failed("システム音声: 起動できない") })
        #expect(await eventually { restartAttempts(in: sut.collector.events) == [1, 2, 3, nil] })
    }

    // MARK: 失敗で閉じる（停止と同じ手順で閉じ、終わり方を残す）

    /// 失敗しても、そこまでの記録は失敗として閉じる。
    /// 1件でも保存していれば完了を知らせ、タイトル生成とプレイブックを記録できた分に走らせる
    @Test func failureAfterSegmentsFinalizesAsFailedAndReportsTheSession() async {
        let sut = await makeStartedSUT(restartPolicy: singleRestart)
        let segment = TestFixtures.segment(text: "閉会のあいさつ")
        sut.engine.send(.finalized(segment))
        #expect(await eventually { await sut.store.segments == [segment] })

        await interruptUntilGivingUp(sut.capture)

        let failed = SessionEvent.stateChanged(.failed("システム音声: 2回目"))
        #expect(await eventually { sut.collector.events.contains(failed) })
        #expect(await sut.store.finalizedReasons == [.failed("システム音声: 2回目")])
        #expect(finishedSessions(in: sut.collector.events).count == 1)
    }

    /// 閉じた後も失敗の状態で終わる。ポップオーバーは状態から理由を出すため、閉じた後も失敗が見えている
    @Test func failureStaysTheFinalStateAfterTheSessionIsClosed() async throws {
        let sut = await makeStartedSUT()
        sut.engine.send(.finalized(TestFixtures.segment(text: "確定")))
        #expect(await eventually { await sut.store.segments.count == 1 })

        sut.engine.failEvents(Described(message: "認識が止まった"))

        let failed = SessionState.failed("システム音声: 認識が止まった")
        #expect(await eventually { sut.collector.events.contains(.stateChanged(failed)) })
        let events = sut.collector.events
        #expect(stateChanges(in: events) == [.preparing, .recording, .stopping, failed])
        let finishedIndex = try #require(events.firstIndex { if case .sessionFinished = $0 { true } else { false } })
        let failedIndex = try #require(events.firstIndex(of: .stateChanged(failed)))
        #expect(finishedIndex < failedIndex)
        #expect(await sut.session.state == failed)
    }

    /// 何も保存していない失敗では完了を知らせない。空の記録にタイトル生成やプレイブックを走らせても必ず失敗する
    @Test func failureWithoutSegmentsFinalizesWithoutReportingTheSession() async {
        let sut = await makeStartedSUT()

        sut.engine.failEvents(Described(message: "認識が止まった"))

        let failed = SessionEvent.stateChanged(.failed("システム音声: 認識が止まった"))
        #expect(await eventually { sut.collector.events.contains(failed) })
        #expect(await sut.store.finalizedReasons == [.failed("システム音声: 認識が止まった")])
        #expect(finishedSessions(in: sut.collector.events).isEmpty)
    }

    /// 失敗でもエンジンを finish させ、言語の判定待ちで残っていたセグメントを保存してから閉じる。
    /// 諦める判断は失敗したフィードの中継タスクの上で走る。そのタスク自身の完走は待たない（待つと戻らない）
    @Test func failureStoresSegmentsEmittedDuringFinishBeforeFinalizing() async {
        let sut = await makeStartedSUT(restartPolicy: singleRestart)
        let order = OrderLog()
        let pending = TestFixtures.segment(text: "言語の判定待ち")
        sut.engine.eventsOnFinish = [.finalized(pending)]
        sut.engine.onFinish = { order.append("engine.finish") }
        await sut.store.setOnAppend { order.append("store.append") }
        await sut.store.setOnFinalize { order.append("store.finalize") }

        await interruptUntilGivingUp(sut.capture)

        #expect(await eventually { await sut.session.state == .failed("システム音声: 2回目") })
        #expect(order.entries == ["engine.finish", "store.append", "store.finalize"])
        #expect(await sut.store.segments == [pending])
        #expect(await eventually { finishedSessions(in: sut.collector.events).count == 1 })
    }

    /// エンジンの失敗は、そのエンジンの結果を受けるタスクの上で閉じる。そのタスク自身は待たず、
    /// 他のフィードのエンジンが finish で吐き出したセグメントは保存してから閉じる
    @Test func engineFailureStoresTheOtherFeedsLastSegmentsBeforeFinalizing() async {
        let sut = await makeStartedSUT(kinds: [.system, .microphone])
        let pending = TestFixtures.segment(text: "自分の発言", source: .microphone)
        sut.feedDoubles[1].engine.eventsOnFinish = [.finalized(pending)]

        sut.feedDoubles[0].engine.failEvents(Described(message: "認識が止まった"))

        #expect(await eventually { await sut.session.state == .failed("システム音声: 認識が止まった") })
        #expect(await sut.store.segments == [pending])
        #expect(await sut.store.finalizedReasons == [.failed("システム音声: 認識が止まった")])
        for feed in sut.feedDoubles {
            #expect(feed.engine.finishCallCount == 1)
        }
    }

    /// 保存先を確保した後にフィードの起動に失敗したら、起動したものを止めて空のセッションを失敗として閉じる。
    /// 何も記録していないので完了は知らせない
    @Test func startFailureAfterBeginFinalizesAsFailed() async {
        let sut = makeSUT(kinds: [.system, .microphone])
        sut.feedDoubles[1].capture.errorOnStart = Described(message: "許可が無い")

        await sut.session.start(feeds: sut.feeds, locales: [ja])

        #expect(await sut.session.state == .failed("マイク: 許可が無い"))
        #expect(await sut.store.finalizedReasons == [.failed("マイク: 許可が無い")])
        #expect(sut.feedDoubles[0].capture.stopCallCount == 1)
        #expect(sut.feedDoubles[0].engine.finishCallCount == 1)
        #expect(await eventually { sut.collector.events.contains(.stateChanged(.failed("マイク: 許可が無い"))) })
        #expect(finishedSessions(in: sut.collector.events).isEmpty)
    }

    /// 保存先を確保できなかった開始には閉じるものが無い
    @Test func startFailureAtBeginDoesNotFinalize() async {
        let sut = makeSUT()
        await sut.store.setBeginError(Described(message: "保存先に書けない"))

        await sut.session.start(feeds: sut.feeds, locales: [ja])

        #expect(await sut.session.state == .failed("保存先に書けない"))
        #expect(await sut.store.finalizedReasons.isEmpty)
    }

    /// 失敗で閉じている途中の停止は何もせずに戻る。閉じるのは失敗の理由で1回だけで、失敗の状態で終わる
    @Test func stopDuringFailureTeardownLeavesTheFailure() async {
        let gate = ManualSleep(holding: true)
        let sut = await makeStartedSUT()
        sut.capture.onStop = { await gate.sleep(for: .zero) }
        sut.engine.failEvents(Described(message: "認識が止まった"))
        #expect(await eventually { gate.waitingCount == 1 })

        // 閉じている途中の記録に止める側が触れると戻らないため、別タスクで呼んで戻ったことを確かめる
        let returns = OrderLog()
        Task {
            await sut.session.stop()
            returns.append("stop")
        }

        #expect(await eventually { returns.entries == ["stop"] })
        #expect(await sut.session.state == .stopping)
        gate.release()
        #expect(await eventually { await sut.session.state == .failed("システム音声: 認識が止まった") })
        #expect(await sut.store.finalizedReasons == [.failed("システム音声: 認識が止まった")])
        #expect(!sut.collector.events.contains(.stateChanged(.idle)))
    }

    /// 停止の途中に届いた失敗は、停止の終わり方を上書きしない
    @Test func failureDuringStopKeepsTheStop() async {
        let gate = ManualSleep(holding: true)
        let sut = await makeStartedSUT()
        sut.capture.onStop = { await gate.sleep(for: .zero) }
        let stopping = Task { await sut.session.stop() }
        #expect(await eventually { gate.waitingCount == 1 })

        // 停止はこのエンジンの結果を受けるタスクの完走を待つため、戻った時点で失敗の知らせは処理済み
        sut.engine.failEvents(Described(message: "認識が止まった"))
        gate.release()
        await stopping.value

        #expect(await sut.session.state == .idle)
        #expect(await sut.store.finalizedReasons == [.stopped])
        #expect(!sut.collector.events.contains { if case .stateChanged(.failed) = $0 { true } else { false } })
    }

    // MARK: 開始の途中の停止

    /// 認識モデルを準備している間に止められたら、保存先を確保せずに終える
    @Test func stopWhilePreparingEndsWithoutBeginningTheStore() async {
        let gate = ManualSleep(holding: true)
        let sut = makeSUT()
        sut.engine.onPrepare = { await gate.sleep(for: .zero) }
        let starting = Task { await sut.session.start(feeds: sut.feeds, locales: [ja]) }
        #expect(await eventually { gate.waitingCount == 1 })

        await sut.session.stop()
        gate.release()
        await starting.value

        #expect(await sut.session.state == .idle)
        #expect(await sut.store.beganContexts.isEmpty)
        #expect(await sut.store.finalizedReasons.isEmpty)
        #expect(sut.capture.startCallCount == 0)
    }

    /// 保存先を確保している間に止められたら、確保し終えるのを待って停止として1回だけ閉じる。
    /// 閉じるのが確保より先だと、確保されたセッションが開いたまま残る
    @Test func stopWhileTheStoreIsBeginningClosesItOnceAsStopped() async {
        let gate = ManualSleep(holding: true)
        let sut = makeSUT()
        await sut.store.setOnBegin { await gate.sleep(for: .zero) }
        let starting = Task { await sut.session.start(feeds: sut.feeds, locales: [ja]) }
        #expect(await eventually { gate.waitingCount == 1 })

        // 閉じる側は確保の終わりを待つため、別タスクで止める
        let stopping = Task { await sut.session.stop() }
        #expect(await eventually { await sut.session.state == .stopping })
        gate.release()
        await starting.value
        await stopping.value

        #expect(await sut.session.state == .idle)
        #expect(await sut.store.finalizedReasons == [.stopped])
        // SpyStore は確保する前の finalize に参照を返さない。完了が流れたのは、確保し終えてから閉じたから
        #expect(await eventually { finishedSessions(in: sut.collector.events).count == 1 })
        #expect(sut.engine.receivedContexts.isEmpty)
        #expect(sut.capture.startCallCount == 0)
    }

    /// エンジンを起動している間に止められたら、そのエンジンを終わらせ、キャプチャは起動しない
    @Test func stopWhileTheEngineIsStartingFinishesItWithoutStartingTheCapture() async {
        let gate = ManualSleep(holding: true)
        let sut = makeSUT()
        sut.engine.onStart = { await gate.sleep(for: .zero) }
        let starting = Task { await sut.session.start(feeds: sut.feeds, locales: [ja]) }
        #expect(await eventually { gate.waitingCount == 1 })

        await sut.session.stop()
        gate.release()
        await starting.value

        #expect(await sut.session.state == .idle)
        #expect(sut.engine.finishCallCount == 1)
        #expect(sut.capture.startCallCount == 0)
        #expect(await sut.store.finalizedReasons == [.stopped])
    }

    /// キャプチャを起動している間に止められたら、.recording に入らずに終える。
    /// 起動の途中のキャプチャに stop を重ねず、起動し終えたところで1回だけ止める。中継していたフィードは停止が止める
    @Test func stopWhileACaptureIsStartingEndsWithoutRecording() async {
        let gate = ManualSleep(holding: true)
        let sut = makeSUT(kinds: [.system, .microphone])
        let microphone = sut.feedDoubles[1].capture
        microphone.onStart = { await gate.sleep(for: .zero) }
        let starting = Task { await sut.session.start(feeds: sut.feeds, locales: [ja]) }
        #expect(await eventually { gate.waitingCount == 1 })

        await sut.session.stop()
        gate.release()
        await starting.value

        #expect(await sut.session.state == .idle)
        #expect(!sut.collector.events.contains(.stateChanged(.recording)))
        for feed in sut.feedDoubles {
            #expect(feed.capture.startCallCount == 1)
            #expect(feed.capture.stopCallCount == 1)
            #expect(feed.capture.maxConcurrentCalls == 1)
            #expect(!feed.capture.isCapturing)
        }
        #expect(await sut.store.finalizedReasons == [.stopped])
    }

    /// 止められた後にキャプチャの起動が失敗しても、掴みかけたものを放すため1回だけ止める。失敗として閉じ直さない
    @Test func captureStartFailingAfterStopIsStoppedOnceWithoutFailing() async {
        let gate = ManualSleep(holding: true)
        let sut = makeSUT()
        sut.capture.onStart = { await gate.sleep(for: .zero) }
        sut.capture.errorOnStart = Described(message: "許可が無い")
        let starting = Task { await sut.session.start(feeds: sut.feeds, locales: [ja]) }
        #expect(await eventually { gate.waitingCount == 1 })

        await sut.session.stop()
        gate.release()
        await starting.value

        #expect(await sut.session.state == .idle)
        #expect(sut.capture.stopCallCount == 1)
        #expect(sut.capture.maxConcurrentCalls == 1)
        #expect(await sut.store.finalizedReasons == [.stopped])
    }

    /// 止められた開始が待ちから戻ったとき、次の記録の準備が始まっていても続きを進めない
    @Test func stoppedStartDoesNotContinueIntoTheNextRecording() async {
        let firstGate = ManualSleep(holding: true)
        let secondGate = ManualSleep(holding: true)
        let sut = makeSUT()
        sut.engine.onPrepare = { await firstGate.sleep(for: .zero) }
        let first = Task { await sut.session.start(feeds: sut.feeds, locales: [ja]) }
        #expect(await eventually { firstGate.waitingCount == 1 })
        await sut.session.stop()
        let next = FeedDoubles(capture: FakeCaptureSource(), engine: FakeTranscriptionEngine(), kind: .system)
        next.engine.onPrepare = { await secondGate.sleep(for: .zero) }
        let second = Task { await sut.session.start(feeds: [next.feed], locales: [ja]) }
        #expect(await eventually { secondGate.waitingCount == 1 })

        firstGate.release()
        await first.value
        secondGate.release()
        await second.value

        #expect(await sut.session.state == .recording)
        #expect(await sut.store.beganContexts.count == 1)
        #expect(sut.engine.receivedContexts.isEmpty)
        #expect(sut.capture.startCallCount == 0)
        #expect(next.capture.startCallCount == 1)
    }

    // MARK: 開始の途中の中断と失敗

    /// 起動の途中（.preparing）に届いた中断も落とさない。中断はすぐ知らせるが、他のキャプチャを起動している間は
    /// 中断したキャプチャに触れず、.recording に入ってから再起動の方針どおりに再起動する
    @Test func interruptionWhilePreparingRestartsTheFeedOnceRecording() async {
        let gate = ManualSleep(holding: true)
        let sut = makeSUT(kinds: [.system, .microphone])
        let system = sut.feedDoubles[0].capture
        sut.feedDoubles[1].capture.onStart = { await gate.sleep(for: .zero) }
        let starting = Task { await sut.session.start(feeds: sut.feeds, locales: [ja]) }
        #expect(await eventually { gate.waitingCount == 1 })

        system.fail(Described(message: "構成が変わった"))

        #expect(await eventually {
            interruptions(in: sut.collector.events) == [
                CaptureInterruption(source: .system, reason: "構成が変わった", restartAttempt: 1),
            ]
        })
        #expect(system.stopCallCount == 0)
        #expect(system.startCallCount == 1)
        gate.release()
        await starting.value
        #expect(await eventually { system.startCallCount == 2 })
        #expect(await sut.session.state == .recording)
        #expect(system.maxConcurrentCalls == 1)
        system.emit(AudioChunk(buffer: TestSignal.sine(format: sut.feedDoubles[0].engine.prepareFormat, seconds: 0.1)))
        #expect(await eventually { sut.feedDoubles[0].engine.consumedChunkCount == 1 })
    }

    /// 起動の途中に中断したまま止められたら、再起動せずに閉じる。中断したキャプチャは停止が1回だけ止める
    @Test func stopAfterAnInterruptionWhilePreparingClosesWithoutRestarting() async {
        let gate = ManualSleep(holding: true)
        let sut = makeSUT(kinds: [.system, .microphone])
        let system = sut.feedDoubles[0].capture
        sut.feedDoubles[1].capture.onStart = { await gate.sleep(for: .zero) }
        let starting = Task { await sut.session.start(feeds: sut.feeds, locales: [ja]) }
        #expect(await eventually { gate.waitingCount == 1 })
        system.fail(Described(message: "構成が変わった"))
        #expect(await eventually { !interruptions(in: sut.collector.events).isEmpty })

        await sut.session.stop()
        gate.release()
        await starting.value

        #expect(await sut.session.state == .idle)
        #expect(system.startCallCount == 1)
        #expect(system.stopCallCount == 1)
        #expect(await sut.store.finalizedReasons == [.stopped])
    }

    /// 起動の途中にエンジンが失敗したら、起動に失敗したのと同じく記録全体を失敗として閉じる。
    /// エンジンの失敗は再起動では直らないため待たない。起動の途中のキャプチャは起動し終えたところで1回だけ止まる
    @Test func engineFailureWhilePreparingFailsTheStart() async {
        let gate = ManualSleep(holding: true)
        let sut = makeSUT(kinds: [.system, .microphone])
        let microphone = sut.feedDoubles[1].capture
        microphone.onStart = { await gate.sleep(for: .zero) }
        let starting = Task { await sut.session.start(feeds: sut.feeds, locales: [ja]) }
        #expect(await eventually { gate.waitingCount == 1 })

        sut.feedDoubles[0].engine.failEvents(Described(message: "認識が止まった"))

        #expect(await eventually { await sut.session.state == .failed("システム音声: 認識が止まった") })
        gate.release()
        await starting.value
        #expect(await sut.session.state == .failed("システム音声: 認識が止まった"))
        #expect(await sut.store.finalizedReasons == [.failed("システム音声: 認識が止まった")])
        #expect(microphone.stopCallCount == 1)
        #expect(microphone.maxConcurrentCalls == 1)
        #expect(!sut.collector.events.contains(.stateChanged(.recording)))
    }

    // MARK: 無音での自動停止

    /// どの音源からも発話が届かないまま silenceTimeout が過ぎたら、停止と同じ手順で閉じる。
    /// 止める理由を先に知らせ、終わり方は autoStopped で残し、停止と同じく完了を知らせる（タイトル生成とプレイブックの起点）
    @Test func silenceForTheTimeoutClosesTheSessionAsAutoStopped() async throws {
        let clock = TestClock()
        let startedAt = clock.now
        let watchdog = ManualSleep(holding: true)
        let sut = await makeStartedSUT(
            now: { clock.now }, sleep: { await watchdog.sleep(for: $0) }, silenceTimeout: .seconds(60)
        )
        #expect(await eventually { watchdog.waitingCount == 1 })
        clock.advance(by: .seconds(59))
        await stepWatchdogExpectingItToKeepWatching(watchdog)
        #expect(await sut.session.state == .recording)

        clock.advance(by: .seconds(1))
        watchdog.step()

        #expect(await eventually { sut.collector.events.contains(.stateChanged(.idle)) })
        #expect(await sut.session.state == .idle)
        #expect(await sut.store.finalizedReasons == [.autoStopped])
        #expect(await sut.store.finalizedAts == [startedAt.addingTimeInterval(60)])
        #expect(!sut.capture.isCapturing)
        #expect(sut.engine.finishCallCount == 1)
        let events = sut.collector.events
        #expect(stateChanges(in: events) == [.preparing, .recording, .stopping, .idle])
        #expect(finishedSessions(in: events).count == 1)
        let autoStopIndex = try #require(events.firstIndex(of: .autoStopped(silence: .seconds(60))))
        let stoppingIndex = try #require(events.firstIndex(of: .stateChanged(.stopping)))
        #expect(autoStopIndex < stoppingIndex)
    }

    /// 途中経過の字幕でも、発話が届けばその時刻から数え直す
    @Test func liveTranscriptPushesTheAutoStopBack() async {
        let clock = TestClock()
        let startedAt = clock.now
        let watchdog = ManualSleep(holding: true)
        let sut = await makeStartedSUT(
            now: { clock.now }, sleep: { await watchdog.sleep(for: $0) }, silenceTimeout: .seconds(60)
        )
        #expect(await eventually { watchdog.waitingCount == 1 })
        clock.advance(by: .seconds(45))
        sut.engine.send(.volatile("こんにちは"))
        #expect(await eventually { sut.collector.events.contains(.liveTranscript("こんにちは")) })

        // 開始からは timeout を過ぎているが、発話からは59秒
        clock.advance(by: .seconds(59))
        await stepWatchdogExpectingItToKeepWatching(watchdog)
        #expect(await sut.session.state == .recording)
        clock.advance(by: .seconds(1))
        watchdog.step()

        #expect(await eventually { await sut.session.state == .idle })
        #expect(await sut.store.finalizedReasons == [.autoStopped])
        #expect(await sut.store.finalizedAts == [startedAt.addingTimeInterval(105)])
    }

    /// 確定した発話も数え直す。どの音源から届いてもよい（自分の発言だけが続く場面もある）
    @Test func finalizedSpeechFromAnyFeedPushesTheAutoStopBack() async {
        let clock = TestClock()
        let watchdog = ManualSleep(holding: true)
        let sut = await makeStartedSUT(
            kinds: [.system, .microphone], now: { clock.now },
            sleep: { await watchdog.sleep(for: $0) }, silenceTimeout: .seconds(60)
        )
        #expect(await eventually { watchdog.waitingCount == 1 })
        clock.advance(by: .seconds(45))
        let segment = TestFixtures.segment(text: "自分の発言", source: .microphone)
        sut.feedDoubles[1].engine.send(.finalized(segment))
        #expect(await eventually { await sut.store.segments == [segment] })

        clock.advance(by: .seconds(59))
        await stepWatchdogExpectingItToKeepWatching(watchdog)

        #expect(await sut.session.state == .recording)
        await sut.session.stop()
        watchdog.release()
    }

    /// 雑音に認識器が返す句読点だけの結果では数え直さず、開始から timeout で止める
    @Test func punctuationOnlyResultsDoNotPushTheAutoStopBack() async {
        let clock = TestClock()
        let startedAt = clock.now
        let watchdog = ManualSleep(holding: true)
        let sut = await makeStartedSUT(
            now: { clock.now }, sleep: { await watchdog.sleep(for: $0) }, silenceTimeout: .seconds(60)
        )
        #expect(await eventually { watchdog.waitingCount == 1 })
        clock.advance(by: .seconds(45))
        sut.engine.send(.volatile(", , ,"))
        let punctuation = TestFixtures.segment(text: "、。")
        sut.engine.send(.finalized(punctuation))
        #expect(await eventually { await sut.store.segments == [punctuation] })

        clock.advance(by: .seconds(15))
        watchdog.step()

        #expect(await eventually { await sut.session.state == .idle })
        #expect(await sut.store.finalizedReasons == [.autoStopped])
        #expect(await sut.store.finalizedAts == [startedAt.addingTimeInterval(60)])
    }

    /// silenceTimeout を渡さなければ見張らない。何時間無音が続いても自分では止まらない
    @Test func withoutASilenceTimeoutTheSessionNeverStopsItself() async {
        let clock = TestClock()
        let sleep = ManualSleep(holding: true)
        let sut = await makeStartedSUT(now: { clock.now }, sleep: { await sleep.sleep(for: $0) })

        clock.advance(by: .seconds(24 * 60 * 60))
        // 見張りがあれば、結果の保存を待つ間に最初の待ちへ入っている
        let segment = TestFixtures.segment(text: "確定")
        sut.engine.send(.finalized(segment))
        #expect(await eventually { await sut.store.segments == [segment] })

        #expect(sleep.requestedDurations.isEmpty)
        #expect(await sut.session.state == .recording)
        #expect(!sut.collector.events.contains(where: isAutoStop))
    }

    /// 無音は記録が始まってから数える。準備（認識モデルのダウンロード）が timeout より長引いても、準備の間は見張らない。
    /// 準備の間から見張ると、準備の時間まで無音に数えて早く止めるか、最初の確認で .preparing を見て見張りを終え、その記録は無音で止まらなくなる
    @Test func silenceIsCountedFromTheStartOfRecordingNotFromPreparation() async {
        let clock = TestClock()
        let preparation = ManualSleep(holding: true)
        let watchdog = ManualSleep(holding: true)
        let sut = makeSUT(now: { clock.now }, sleep: { await watchdog.sleep(for: $0) })
        sut.engine.onPrepare = { await preparation.sleep(for: .zero) }
        let starting = Task { await sut.session.start(feeds: sut.feeds, locales: [ja], silenceTimeout: .seconds(60)) }
        #expect(await eventually { preparation.waitingCount == 1 })
        // 準備の間に見張りが確かめる時期を過ぎた
        clock.advance(by: .seconds(90))
        watchdog.step()
        preparation.release()
        await starting.value
        let recordingStartedAt = clock.now

        #expect(await eventually { watchdog.waitingCount == 1 })
        clock.advance(by: .seconds(59))
        await stepWatchdogExpectingItToKeepWatching(watchdog)
        #expect(await sut.session.state == .recording)
        clock.advance(by: .seconds(1))
        watchdog.step()

        #expect(await eventually { await sut.session.state == .idle })
        #expect(await sut.store.finalizedReasons == [.autoStopped])
        #expect(await sut.store.finalizedAts == [recordingStartedAt.addingTimeInterval(60)])
    }

    /// 停止は見張りを取り消す。見張りは待ちから戻ったところで取り消しに気づいて抜ける
    @Test func stopCancelsTheSilenceWatchdog() async {
        let gate = ManualSleep(holding: true)
        let cancelled = OrderLog()
        let sut = await makeStartedSUT(
            sleep: sleepNoticingCancellation(gate, cancelled: cancelled), silenceTimeout: .seconds(60)
        )
        #expect(await eventually { gate.waitingCount == 1 })

        await sut.session.stop()
        gate.release()

        #expect(await eventually { cancelled.entries == ["cancelled"] })
        #expect(await sut.store.finalizedReasons == [.stopped])
        #expect(!sut.collector.events.contains(where: isAutoStop))
    }

    /// 失敗で閉じるときも見張りを取り消す
    @Test func failureCancelsTheSilenceWatchdog() async {
        let gate = ManualSleep(holding: true)
        let cancelled = OrderLog()
        let sut = await makeStartedSUT(
            sleep: sleepNoticingCancellation(gate, cancelled: cancelled), silenceTimeout: .seconds(60)
        )
        #expect(await eventually { gate.waitingCount == 1 })

        sut.engine.failEvents(Described(message: "認識が止まった"))
        #expect(await eventually { await sut.session.state == .failed("システム音声: 認識が止まった") })
        gate.release()

        #expect(await eventually { cancelled.entries == ["cancelled"] })
        #expect(!sut.collector.events.contains(where: isAutoStop))
    }

    /// 閉じた記録の見張りが待ちから戻っても、その後に始まった次の記録には何もしない。
    /// 取り消しでは戻らない待ちもあり、戻った見張りが見る状態は次の記録のもの
    @Test func watchdogOfAClosedRecordingNeverStopsTheNextOne() async {
        let clock = TestClock()
        let earlier = ManualSleep(holding: true)
        let later = ManualSleep(holding: true)
        let sleepCalls = OrderLog()
        // 1回目の待ちは最初の記録の見張り、2回目からは次の記録の見張りのもの
        let sut = await makeStartedSUT(now: { clock.now }, sleep: { duration in
            sleepCalls.append("sleep")
            if sleepCalls.entries.count == 1 {
                await earlier.sleep(for: duration)
            } else {
                await later.sleep(for: duration)
            }
        }, silenceTimeout: .seconds(60))
        #expect(await eventually { earlier.waitingCount == 1 })
        await sut.session.stop()
        let next = FeedDoubles(capture: FakeCaptureSource(), engine: FakeTranscriptionEngine(), kind: .system)
        await sut.session.start(feeds: [next.feed], locales: [ja], silenceTimeout: .seconds(60))
        #expect(await eventually { later.waitingCount == 1 })
        // 次の記録も無音のまま timeout を過ぎた。止めてよいのは次の記録の見張りだけ
        clock.advance(by: .seconds(60))

        earlier.release()

        // 待ち明けの確認は actor 上で終わり、外からその終わりを待つ手段は無い。待ちから戻ったのを見てから確かめる。
        // 正しく抜けていれば、確かめる時期によらず何も起きていない
        #expect(await eventually { earlier.returnedCount == 1 })
        #expect(await sut.session.state == .recording)
        #expect(next.capture.isCapturing)
        #expect(await sut.store.finalizedReasons == [.stopped])
        #expect(!sut.collector.events.contains(where: isAutoStop))
        await sut.session.stop()
        later.release()
    }

    /// 自動停止は見張りのタスクの上で閉じる。閉じる側がそのタスクを取り消すと、取り消されたタスクで engine.finish が走り
    /// （SpeechAnalyzer の finalize は CancellationError で抜ける）、finalize が確定させる最後の発話を落とす
    @Test func autoStopStoresTheSegmentsEmittedDuringFinish() async {
        let clock = TestClock()
        let watchdog = ManualSleep(holding: true)
        let sut = await makeStartedSUT(
            now: { clock.now }, sleep: { await watchdog.sleep(for: $0) }, silenceTimeout: .seconds(60)
        )
        let lastWords = TestFixtures.segment(text: "finalize で確定した最後の発話")
        sut.engine.eventsOnFinish = [.finalized(lastWords)]
        #expect(await eventually { watchdog.waitingCount == 1 })

        clock.advance(by: .seconds(60))
        watchdog.step()

        #expect(await eventually { await sut.session.state == .idle })
        #expect(await sut.store.segments == [lastWords])
        #expect(await sut.store.finalizedReasons == [.autoStopped])
    }

    /// 見張りは15秒ごとに確かめる。止めるのは無音が timeout に達してから最大15秒遅れる
    @Test func watchdogChecksEveryFifteenSeconds() async {
        let watchdog = ManualSleep(holding: true)

        let sut = await makeStartedSUT(sleep: { await watchdog.sleep(for: $0) }, silenceTimeout: .seconds(60))

        #expect(await eventually { watchdog.waitingCount == 1 })
        #expect(watchdog.requestedDurations == [.seconds(15)])
        await sut.session.stop()
        watchdog.release()
    }

    /// silenceTimeout が確かめる間隔より短ければ、silenceTimeout ごとに確かめる。間隔ごとでは timeout の何倍も遅れて止まる
    @Test func watchdogChecksAtTheTimeoutWhenItIsShorterThanTheCheckInterval() async {
        let watchdog = ManualSleep(holding: true)

        let sut = await makeStartedSUT(sleep: { await watchdog.sleep(for: $0) }, silenceTimeout: .seconds(10))

        #expect(await eventually { watchdog.waitingCount == 1 })
        #expect(watchdog.requestedDurations == [.seconds(10)])
        await sut.session.stop()
        watchdog.release()
    }

    // MARK: 翻訳

    /// 訳はセグメントへ載せてから保存する。ストアには訳つきの1件だけが渡る
    @Test func translatesFinalizedSegmentBeforeStoring() async throws {
        let translator = FakeTranslator()
        translator.result = .success(TranslatedText(text: "Hello", locale: "en-US"))
        let sut = await makeStartedSUT(translator: translator)

        sut.engine.send(.finalized(TestFixtures.segment(text: "こんにちは")))

        #expect(await eventually { await sut.store.segments.count == 1 })
        let stored = try #require(await sut.store.segments.first)
        #expect(stored.translation == "Hello")
        #expect(stored.translationLocale == "en-US")
        #expect(translator.receivedTexts == ["こんにちは"])
        // UI（ライブ字幕・オーバーレイ）は保存済みイベントから訳を受け取る。
        // イベントの購読は別タスクなので、保存完了と同時に届いているとは限らない
        #expect(await eventually { sut.collector.events.contains(.segmentRecorded(stored)) })
    }

    /// 翻訳が失敗しても記録は止めない。原文だけ保存し、UI へは別途通知する
    @Test func keepsRecordingWhenTranslationFails() async throws {
        let translator = FakeTranslator()
        translator.result = .failure(Boom())
        let sut = await makeStartedSUT(translator: translator)

        sut.engine.send(.finalized(TestFixtures.segment(text: "こんにちは")))

        #expect(await eventually { await sut.store.segments.count == 1 })
        let stored = try #require(await sut.store.segments.first)
        #expect(stored.translation == nil)
        #expect(await eventually {
            sut.collector.events.contains { if case .translationError = $0 { true } else { false } }
        })
        #expect(await sut.session.state == .recording)
    }

    /// 翻訳が返らないときも保存は進む。記録を翻訳の人質にしない
    @Test func storesOriginalWhenTranslationTimesOut() async {
        let translator = FakeTranslator()
        translator.delay = .seconds(60)
        let sut = await makeStartedSUT(translator: translator, translationTimeout: .milliseconds(50))

        sut.engine.send(.finalized(TestFixtures.segment(text: "こんにちは")))

        #expect(await eventually { await sut.store.segments.count == 1 })
        #expect(await sut.store.segments.first?.translation == nil)
        #expect(await sut.session.state == .recording)
    }

    /// 翻訳器が無ければ従来どおり原文だけが流れる
    @Test func storesOriginalWhenTranslatorIsAbsent() async {
        let sut = await makeStartedSUT()

        sut.engine.send(.finalized(TestFixtures.segment(text: "こんにちは")))

        #expect(await eventually { await sut.store.segments.count == 1 })
        #expect(await sut.store.segments.first?.translation == nil)
    }

    // MARK: Private

    private struct FeedDoubles {
        let capture: FakeCaptureSource
        let engine: FakeTranscriptionEngine
        let kind: AudioSourceKind

        var feed: RecordingFeed {
            RecordingFeed(capture: capture, engine: engine, kind: kind)
        }
    }

    private struct SUT {
        let session: RecordingSession
        let feedDoubles: [FeedDoubles]
        let store: SpyStore
        let collector: EventCollector

        /// 単一フィードのテスト向けショートカット
        var capture: FakeCaptureSource {
            feedDoubles[0].capture
        }

        var engine: FakeTranscriptionEngine {
            feedDoubles[0].engine
        }

        var feeds: [RecordingFeed] {
            feedDoubles.map(\.feed)
        }
    }

    private var ja: Locale {
        Locale(identifier: "ja-JP")
    }

    /// 2回目の連続した中断で諦める方針。諦めた後の振る舞いを短い手順で確かめるため
    private var singleRestart: CaptureRestartPolicy {
        var policy = CaptureRestartPolicy.default
        policy.maxConsecutiveRestarts = 1
        return policy
    }

    /// sleep の既定は待たずに戻る。再起動を含むテストが実時間の settleDelay を待たないように。
    /// 無音を見張るテストは、見張りが空回りしないよう待つ sleep（ManualSleep）を渡す
    private func makeSUT(
        kinds: [AudioSourceKind] = [.system],
        now: @escaping @Sendable () -> Date = { Date() },
        makeSessionID: @escaping @Sendable () -> UUID = { UUID() },
        translationTimeout: Duration = .seconds(10),
        restartPolicy: CaptureRestartPolicy = .default,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) -> SUT {
        let feedDoubles = kinds.map {
            FeedDoubles(capture: FakeCaptureSource(), engine: FakeTranscriptionEngine(), kind: $0)
        }
        let store = SpyStore()
        let session = RecordingSession(
            store: store,
            translationTimeout: translationTimeout,
            restartPolicy: restartPolicy,
            now: now, makeSessionID: makeSessionID,
            sleep: sleep
        )
        let collector = EventCollector()
        collector.attach(to: session.events)
        return SUT(session: session, feedDoubles: feedDoubles, store: store, collector: collector)
    }

    private func makeStartedSUT(
        kinds: [AudioSourceKind] = [.system],
        now: @escaping @Sendable () -> Date = { Date() },
        translator: (any Translator)? = nil,
        translationTimeout: Duration = .seconds(10),
        restartPolicy: CaptureRestartPolicy = .default,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in },
        silenceTimeout: Duration? = nil
    ) async -> SUT {
        let sut = makeSUT(
            kinds: kinds, now: now, translationTimeout: translationTimeout,
            restartPolicy: restartPolicy, sleep: sleep
        )
        // 翻訳器はロケールごとに引かれる。テストではどのロケールでも同じものを返す
        var factory: (@Sendable (String) -> (any Translator)?)?
        if let translator {
            factory = { _ in translator }
        }
        await sut.session.start(
            feeds: sut.feeds, locales: [ja], makeTranslator: factory, silenceTimeout: silenceTimeout
        )
        _ = await eventually { await sut.session.state == .recording }
        return sut
    }

    private func interruptions(in events: [SessionEvent]) -> [CaptureInterruption] {
        events.compactMap { event -> CaptureInterruption? in
            if case let .captureInterrupted(interruption) = event { interruption } else { nil }
        }
    }

    private func restartAttempts(in events: [SessionEvent]) -> [Int?] {
        interruptions(in: events).map(\.restartAttempt)
    }

    private func stateChanges(in events: [SessionEvent]) -> [SessionState] {
        events.compactMap { event -> SessionState? in
            if case let .stateChanged(state) = event { state } else { nil }
        }
    }

    private func finishedSessions(in events: [SessionEvent]) -> [SessionRef] {
        events.compactMap { event -> SessionRef? in
            if case let .sessionFinished(ref) = event { ref } else { nil }
        }
    }

    /// singleRestart のもとで、1回目の中断は再起動させ、2回目で諦めさせる
    private func interruptUntilGivingUp(_ capture: FakeCaptureSource) async {
        capture.fail(Described(message: "1回目"))
        #expect(await eventually { capture.startCallCount == 2 })
        capture.fail(Described(message: "2回目"))
    }

    private func isAutoStop(_ event: SessionEvent) -> Bool {
        if case .autoStopped = event { true } else { false }
    }

    /// 実際の待ち（Task.sleep）と同じく、戻ったときにタスクが取り消されていたら CancellationError を投げる sleep。
    /// 取り消しに気づいて抜けた回数を cancelled に残す
    private func sleepNoticingCancellation(
        _ gate: ManualSleep, cancelled: OrderLog
    ) -> @Sendable (Duration) async throws -> Void {
        { duration in
            await gate.sleep(for: duration)
            if Task.isCancelled {
                cancelled.append("cancelled")
                throw CancellationError()
            }
        }
    }

    /// 見張りを1周進め、無音が続いていないと判断して次の待ちに入ったところまで待つ
    private func stepWatchdogExpectingItToKeepWatching(_ watchdog: ManualSleep) async {
        let requested = watchdog.requestedDurations.count
        watchdog.step()
        #expect(await eventually { watchdog.requestedDurations.count == requested + 1 })
    }
}
