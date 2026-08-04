import AVFAudio
import Foundation
@testable import OtoLogCore
import Testing

struct BufferConverterTests {
    let source48k2ch = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let source44k1ch = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    let target16k1ch = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!

    @Test func accumulatesProportionalFramesAcrossConsecutiveBuffers() {
        let converter = BufferConverter()

        // リサンプラは末尾 (約15ms) を内部保持するため、単発でなく連続変換の累積で比例を検証する
        var totalFrames = 0
        for _ in 0..<3 {
            let output = converter.convert(TestSignal.sine(format: source48k2ch, seconds: 0.1), to: target16k1ch)
            #expect(output?.format == target16k1ch)
            totalFrames += Int(output?.frameLength ?? 0)
        }

        let expected = 4800 // 0.3秒 × 16kHz
        #expect(totalFrames <= expected)
        #expect(expected - totalFrames <= 320) // 保持分は20ms相当まで許容
    }

    @Test func survivesInputFormatChangeMidStream() {
        let converter = BufferConverter()
        let first = converter.convert(TestSignal.sine(format: source48k2ch, seconds: 0.1), to: target16k1ch)
        let second = converter.convert(TestSignal.sine(format: source44k1ch, seconds: 0.1), to: target16k1ch)

        #expect(first != nil)
        #expect(second != nil)
        #expect(second?.format == target16k1ch)
    }

    @Test func returnsNilForEmptyBuffer() throws {
        let converter = BufferConverter()
        let empty = try #require(AVAudioPCMBuffer(pcmFormat: source48k2ch, frameCapacity: 1024))

        #expect(converter.convert(empty, to: target16k1ch) == nil)
    }

    @Test func passesThroughWhenFormatsMatch() {
        let converter = BufferConverter()
        let input = TestSignal.sine(format: target16k1ch, seconds: 0.1)

        let output = converter.convert(input, to: target16k1ch)

        #expect(output === input)
    }

    /// タップコールバック所有のバッファを yield 後も安全に使うための所有コピー保証。
    /// フォーマット一致の素通しでも入力と同じインスタンスは返さない
    @Test func convertOwnedReturnsCallerOwnedCopyWhenFormatsMatch() {
        let converter = BufferConverter()
        let input = TestSignal.sine(format: target16k1ch, seconds: 0.1)

        let output = converter.convertOwned(input, to: target16k1ch)

        #expect(output !== input)
        #expect(output?.frameLength == input.frameLength)
        #expect(output?.format == target16k1ch)
    }

    @Test func convertOwnedStillConvertsAcrossFormats() {
        let converter = BufferConverter()

        let output = converter.convertOwned(TestSignal.sine(format: source48k2ch, seconds: 0.1), to: target16k1ch)

        #expect(output?.format == target16k1ch)
        #expect((output?.frameLength ?? 0) > 0)
    }
}
