@preconcurrency import AVFAudio
import Foundation
@testable import OtoLogCore
import Testing

struct RecordingSessionTests {
    // MARK: Internal

    struct Boom: Error {}

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
            feedDoubles.map { RecordingFeed(capture: $0.capture, engine: $0.engine, kind: $0.kind) }
        }
    }

    private var ja: Locale {
        Locale(identifier: "ja-JP")
    }

    private func makeSUT(
        kinds: [AudioSourceKind] = [.system],
        now: @escaping @Sendable () -> Date = { Date() },
        makeSessionID: @escaping @Sendable () -> UUID = { UUID() },
        translationTimeout: Duration = .seconds(10)
    ) -> SUT {
        let feedDoubles = kinds.map {
            FeedDoubles(capture: FakeCaptureSource(), engine: FakeTranscriptionEngine(), kind: $0)
        }
        let store = SpyStore()
        let session = RecordingSession(
            store: store,
            translationTimeout: translationTimeout,
            now: now, makeSessionID: makeSessionID
        )
        let collector = EventCollector()
        collector.attach(to: session.events)
        return SUT(session: session, feedDoubles: feedDoubles, store: store, collector: collector)
    }

    private func makeStartedSUT(
        kinds: [AudioSourceKind] = [.system],
        now: @escaping @Sendable () -> Date = { Date() },
        translator: (any Translator)? = nil,
        translationTimeout: Duration = .seconds(10)
    ) async -> SUT {
        let sut = makeSUT(kinds: kinds, now: now, translationTimeout: translationTimeout)
        // 翻訳器はロケールごとに引かれる。テストではどのロケールでも同じものを返す
        var factory: (@Sendable (String) -> (any Translator)?)?
        if let translator {
            factory = { _ in translator }
        }
        await sut.session.start(feeds: sut.feeds, locales: [ja], makeTranslator: factory)
        _ = await eventually { await sut.session.state == .recording }
        return sut
    }
}
