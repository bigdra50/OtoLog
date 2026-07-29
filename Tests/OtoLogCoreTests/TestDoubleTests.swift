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

        _ = try await engine.prepare(locale: Locale(identifier: "ja-JP"), onProgress: { _ in })
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
