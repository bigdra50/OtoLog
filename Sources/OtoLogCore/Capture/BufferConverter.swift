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

    /// convert と同じだが、返すバッファは常に呼び出し側が所有する。
    /// フォーマット一致の素通しではコールバック所有のバッファがそのまま返るため、
    /// yield 後にコールバック側で再利用されても安全なよう複製してから返す
    public func convertOwned(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converted = convert(buffer, to: targetFormat) else { return nil }
        return converted === buffer ? Self.ownedCopy(of: converted) : converted
    }

    // MARK: Internal

    /// サンプル型（Float32/Int16）に依存しないよう audioBufferList を丸ごと複製する
    static func ownedCopy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in 0..<sourceBuffers.count {
            guard let source = sourceBuffers[index].mData,
                  let destination = destinationBuffers[index].mData else { return nil }
            let bytes = min(sourceBuffers[index].mDataByteSize, destinationBuffers[index].mDataByteSize)
            memcpy(destination, source, Int(bytes))
            destinationBuffers[index].mDataByteSize = bytes
        }
        return copy
    }

    // MARK: Private

    private var converter: AVAudioConverter?
}
