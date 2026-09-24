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
}
