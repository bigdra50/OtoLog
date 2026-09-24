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

    /// sleep の既定は待たずに戻る。再起動を含むテストが実時間の settleDelay を待たないように
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
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
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
        await sut.session.start(feeds: sut.feeds, locales: [ja], makeTranslator: factory)
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
}
