import Foundation
@testable import OtoLogCore
import Testing

struct RecordingSessionTests {
    // MARK: Internal

    struct Boom: Error {}

    @Test func startEmitsPreparingProgressThenRecording() async {
        let sut = makeSUT()
        sut.engine.progressScript = [0.5]

        await sut.session.start(locale: ja)

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

        await sut.session.start(locale: ja)

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

        await sut.session.start(locale: ja)

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

        await sut.session.start(locale: ja)

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

    @Test func secondCaptureFailureLeadsToFailed() async {
        let sut = await makeStartedSUT()

        sut.capture.fail(Boom())
        #expect(await eventually { sut.capture.startCallCount == 2 })

        sut.capture.fail(Boom())
        #expect(await eventually {
            if case .failed = await sut.session.state { return true }
            return false
        })
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

    // MARK: Private

    private struct SUT {
        let session: RecordingSession
        let capture: FakeCaptureSource
        let engine: FakeTranscriptionEngine
        let store: SpyStore
        let collector: EventCollector
    }

    private var ja: Locale {
        Locale(identifier: "ja-JP")
    }

    private func makeSUT(
        now: @escaping @Sendable () -> Date = { Date() },
        makeSessionID: @escaping @Sendable () -> UUID = { UUID() }
    ) -> SUT {
        let capture = FakeCaptureSource()
        let engine = FakeTranscriptionEngine()
        let store = SpyStore()
        let session = RecordingSession(
            capture: capture, engine: engine, store: store,
            now: now, makeSessionID: makeSessionID
        )
        let collector = EventCollector()
        collector.attach(to: session.events)
        return SUT(session: session, capture: capture, engine: engine, store: store, collector: collector)
    }

    private func makeStartedSUT(
        now: @escaping @Sendable () -> Date = { Date() }
    ) async -> SUT {
        let sut = makeSUT(now: now)
        await sut.session.start(locale: ja)
        _ = await eventually { await sut.session.state == .recording }
        return sut
    }
}
