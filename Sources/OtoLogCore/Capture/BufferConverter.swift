@preconcurrency import AVFAudio
import Foundation

/// PCM バッファをターゲットフォーマットへ変換する。
/// 入力フォーマットが途中で変わったらコンバータを作り直す（yap AudioStreamDelegate と同方式）。
/// 単一のキャプチャキューから呼ぶ規約のもとで @unchecked Sendable として扱う。
public final class BufferConverter: @unchecked Sendable {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public func convert(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let sourceFormat = buffer.format
        if sourceFormat == targetFormat { return buffer }

        if converter == nil || converter?.inputFormat != sourceFormat || converter?.outputFormat != targetFormat {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        guard let converter else { return nil }

        let capacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate)
        ) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var error: NSError?
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let sourceBuffer = buffer
        converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    // MARK: Private

    private var converter: AVAudioConverter?
}
