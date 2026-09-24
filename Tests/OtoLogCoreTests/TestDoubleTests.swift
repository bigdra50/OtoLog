import AVFAudio
import Foundation
@testable import OtoLogCore
import Testing

/// テストダブル自体の仕様化テスト。
/// Fake の挙動が崩れると上位テストの信頼が崩れるため、最低限をここで固定する。
struct TestDoubleTests {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!

    @Test func signalGeneratesRequestedFrameCount() {
        let buffer = TestSignal.sine(format: format, seconds: 0.5)
        #expect(buffer.frameLength == 8000)
        #expect(buffer.format.sampleRate == 16000)
    }

    @Test func fakeCaptureSourceYieldsInitialChunksAndFinishesOnStop() async throws {
        let source = FakeCaptureSource()
        source.initialChunks = [
            AudioChunk(buffer: TestSignal.sine(format: format, seconds: 0.1)),
            AudioChunk(buffer: TestSignal.sine(format: format, seconds: 0.1)),
        ]
        let stream = try await source.start(targetFormat: format)
        await source.stop()

        var received = 0
        for try await _ in stream {
            received += 1
        }
        #expect(received == 2)
        #expect(source.startCallCount == 1)
        #expect(source.stopCallCount == 1)
        #expect(source.receivedTargetFormats.first?.sampleRate == 16000)
    }

    @Test func fakeCaptureSourceStreamThrowsWhenFailed() async throws {
        struct Boom: Error {}
        let source = FakeCaptureSource()
        let stream = try await source.start(targetFormat: format)
        source.fail(Boom())

        await #expect(throws: Boom.self) {
            for try await _ in stream {}
        }
    }

    /// 順に投げるエラーを使い切ったら、次の start は成功する
    @Test func fakeCaptureSourceThrowsQueuedStartErrorsInOrder() async throws {
        struct First: Error {}
        struct Second: Error {}
        let source = FakeCaptureSource()
        source.startErrors = [First(), Second()]

        await #expect(throws: First.self) { _ = try await source.start(targetFormat: format) }
        await #expect(throws: Second.self) { _ = try await source.start(targetFormat: format) }
        _ = try await source.start(targetFormat: format)

        #expect(source.startCallCount == 3)
        #expect(source.startErrors.isEmpty)
    }

    /// 順に呼んだ start と stop は重なりに数えず、stop の途中で呼ばれた stop は重なりに数える
    @Test func fakeCaptureSourceRecordsOverlappingCalls() async throws {
        let source = FakeCaptureSource()
        _ = try await source.start(targetFormat: format)
        await source.stop()
        #expect(source.maxConcurrentCalls == 1)

        let gate = ManualSleep(holding: true)
        source.onStop = { await gate.sleep(for: .zero) }
        let first = Task { await source.stop() }
        #expect(await eventually { gate.waitingCount == 1 })
        let second = Task { await source.stop() }
        #expect(await eventually { gate.waitingCount == 2 })
        gate.release()
        await first.value
        await second.value

        #expect(source.maxConcurrentCalls == 2)
    }

    /// hold 中は release まで戻らない。release 後の呼び出しは待たずに戻る
    @Test func manualSleepHoldsCallersUntilReleased() async {
        let sleep = ManualSleep(holding: true)
        let held = Task { await sleep.sleep(for: .seconds(1)) }
        #expect(await eventually { sleep.waitingCount == 1 })
        #expect(sleep.returnedCount == 0)

        sleep.release()
        await held.value
        await sleep.sleep(for: .milliseconds(5))

        #expect(sleep.returnedCount == 2)
        #expect(sleep.waitingCount == 0)
        #expect(sleep.requestedDurations == [.seconds(1), .milliseconds(5)])
    }

    /// step は待っている呼び出しだけを戻す。release と違い、以降の呼び出しは引き続き待たせる
    @Test func manualSleepStepReturnsOnlyTheWaitingCallers() async {
        let sleep = ManualSleep(holding: true)
        let first = Task { await sleep.sleep(for: .seconds(1)) }
        #expect(await eventually { sleep.waitingCount == 1 })

        sleep.step()
        await first.value
        let second = Task { await sleep.sleep(for: .seconds(2)) }

        #expect(await eventually { sleep.waitingCount == 1 })
        #expect(sleep.returnedCount == 1)
        sleep.release()
        await second.value
        #expect(sleep.requestedDurations == [.seconds(1), .seconds(2)])
    }

    @Test func spyStoreRecordsAndCanThrow() async throws {
        struct DiskFull: Error {}
        let store = SpyStore()
        try await store.append(TestFixtures.segment(text: "a"))
        await store.setError(DiskFull())
        await #expect(throws: DiskFull.self) {
            try await store.append(TestFixtures.segment(text: "b"))
        }
        let recorded = await store.segments
        #expect(recorded.map(\.text) == ["a"])
    }

    /// begin する前の finalize には参照を返さない。閉じたのが確保の後かどうかを、上位テストはこれで見分ける
    @Test func spyStoreFinalizeReturnsARefOnlyAfterBegin() async throws {
        let store = SpyStore()
        let context = TranscriptionContext(
            locale: "ja-JP", source: .system,
            sessionID: UUID(), sessionStartedAt: Date()
        )

        let beforeBegin = try await store.finalize(endedAt: Date(), reason: .stopped)
        try await store.begin(context: context)
        let afterBegin = try await store.finalize(endedAt: Date(), reason: .failed("止まった"))

        #expect(beforeBegin == nil)
        #expect(afterBegin != nil)
        #expect(await store.finalizedReasons == [.stopped, .failed("止まった")])
    }

    @Test func fakeTextGeneratorRecordsPromptsAndCanThrow() async throws {
        struct Offline: Error {}
        let generator = FakeTextGenerator(result: "生成結果")
        let output = try await generator.generate(prompt: "プロンプトA")
        #expect(output == "生成結果")
        #expect(generator.receivedPrompts == ["プロンプトA"])

        generator.errorToThrow = Offline()
        await #expect(throws: Offline.self) {
            _ = try await generator.generate(prompt: "プロンプトB")
        }
        #expect(generator.receivedPrompts == ["プロンプトA", "プロンプトB"])
    }

    @Test func fakeEngineStreamsScriptedEventsAndCountsChunks() async throws {
        let engine = FakeTranscriptionEngine()
        let source = FakeCaptureSource()
        source.initialChunks = [AudioChunk(buffer: TestSignal.sine(format: format, seconds: 0.1))]

        _ = try await engine.prepare(locales: [Locale(identifier: "ja-JP")], onProgress: { _ in })
        let chunks = try await source.start(targetFormat: format)
        let context = TranscriptionContext(
            locale: "ja-JP", source: .system,
            sessionID: UUID(), sessionStartedAt: Date()
        )
        let events = try await engine.start(chunks: chunks, context: context)

        engine.send(.volatile("live"))
        engine.finishEvents()

        var received: [TranscriptEvent] = []
        for try await event in events {
            received.append(event)
        }
        #expect(received == [.volatile("live")])

        await source.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.consumedChunkCount == 1)
    }

    /// finish はイベント列を閉じる前に eventsOnFinish を流す。実エンジンが判定待ちのセグメントを finish で吐き出すのと同じ順
    @Test func fakeEngineFlushesEventsOnFinishBeforeClosing() async throws {
        let engine = FakeTranscriptionEngine()
        let pending = TestFixtures.segment(text: "判定待ち")
        engine.eventsOnFinish = [.finalized(pending)]
        let source = FakeCaptureSource()
        let chunks = try await source.start(targetFormat: format)
        let context = TranscriptionContext(
            locale: "ja-JP", source: .system,
            sessionID: UUID(), sessionStartedAt: Date()
        )
        let events = try await engine.start(chunks: chunks, context: context)

        await engine.finish()

        var received: [TranscriptEvent] = []
        for try await event in events {
            received.append(event)
        }
        #expect(received == [.finalized(pending)])
        await source.stop()
    }

    /// 取り消されたタスクで finish すると、eventsOnFinish を流さずにイベント列を閉じる。
    /// 実エンジンの吐き出し（SpeechAnalyzer の finalize）が CancellationError で打ち切られるのと同じ
    @Test func fakeEngineDropsEventsOnFinishWhenFinishedOnACancelledTask() async throws {
        let engine = FakeTranscriptionEngine()
        engine.eventsOnFinish = [.finalized(TestFixtures.segment(text: "判定待ち"))]
        let source = FakeCaptureSource()
        let chunks = try await source.start(targetFormat: format)
        let context = TranscriptionContext(
            locale: "ja-JP", source: .system,
            sessionID: UUID(), sessionStartedAt: Date()
        )
        let events = try await engine.start(chunks: chunks, context: context)

        let finishing = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await engine.finish()
        }
        await finishing.value

        var received: [TranscriptEvent] = []
        for try await event in events {
            received.append(event)
        }
        #expect(received.isEmpty)
        #expect(engine.finishCallCount == 1)
        await source.stop()
    }
}
