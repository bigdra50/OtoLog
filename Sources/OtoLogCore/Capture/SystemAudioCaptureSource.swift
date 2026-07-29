@preconcurrency import AVFAudio
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

// MARK: - SystemAudioCaptureSource

/// ScreenCaptureKit によるシステム音声キャプチャ（要・画面収録 TCC）。
/// SCStream の異常停止は AsyncThrowingStream の throw として表面化し、
/// RecordingSession の自動再起動が受ける。
public final class SystemAudioCaptureSource: AudioCaptureSource, @unchecked Sendable {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public func start(targetFormat: AVAudioFormat) async throws -> AsyncThrowingStream<AudioChunk, any Error> {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.screenRecordingPermissionDenied
        }
        guard let display = content.displays.first else {
            throw CaptureError.screenRecordingPermissionDenied
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(targetFormat.sampleRate)
        config.channelCount = Int(targetFormat.channelCount)
        config.excludesCurrentProcessAudio = true
        // 音声だけ欲しいので映像は最小コストに抑える
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let (stream, continuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        let output = AudioStreamOutput(targetFormat: targetFormat, continuation: continuation)
        self.output = output

        let scStream = SCStream(filter: filter, configuration: config, delegate: output)
        try scStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
        do {
            try await scStream.startCapture()
        } catch {
            throw CaptureError.screenRecordingPermissionDenied
        }
        self.scStream = scStream
        return stream
    }

    public func stop() async {
        try? await scStream?.stopCapture()
        output?.finish()
        scStream = nil
        output = nil
    }

    // MARK: Private

    private var scStream: SCStream?
    private var output: AudioStreamOutput?
    private let sampleQueue = DispatchQueue(label: "com.bigdra50.OtoLog.SystemAudioCapture")
}

// MARK: - AudioStreamOutput

/// CMSampleBuffer → targetFormat チャンク変換。SCStream の sampleHandlerQueue 上で直列に呼ばれる。
private final class AudioStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // MARK: Lifecycle

    init(targetFormat: AVAudioFormat, continuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation) {
        self.targetFormat = targetFormat
        self.continuation = continuation
    }

    // MARK: Internal

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = formatDescription.audioStreamBasicDescription,
              let sourceFormat = AVAudioFormat(
                  standardFormatWithSampleRate: asbd.mSampleRate,
                  channels: asbd.mChannelsPerFrame
              )
        else { return }

        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let sourceBuffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    bufferListNoCopy: audioBufferList.unsafePointer
                ) else { return }

                guard let converted = converter.convert(sourceBuffer, to: targetFormat) else { return }
                // bufferListNoCopy の実体は CMSampleBuffer 所有でこのクロージャ外では無効。
                // フォーマット一致時のパススルーはその参照のままなので所有コピーへ差し替える
                let owned = (converted === sourceBuffer) ? Self.ownedCopy(of: converted) : converted
                if let owned {
                    continuation.yield(AudioChunk(buffer: owned))
                }
            }
        } catch {
            // 不正なサンプルバッファはスキップして次を待つ
        }
    }

    func stream(_: SCStream, didStopWithError error: any Error) {
        // スリープ復帰などでの異常停止。セッション側の再起動経路へ流す
        continuation.finish(throwing: error)
    }

    func finish() {
        continuation.finish()
    }

    // MARK: Private

    private let targetFormat: AVAudioFormat
    private let continuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation
    private let converter = BufferConverter()

    /// サンプル型（Float32/Int16）に依存しないよう audioBufferList を丸ごと複製する
    private static func ownedCopy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
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
}

// MARK: - CaptureError

public enum CaptureError: Error, LocalizedError {
    case screenRecordingPermissionDenied

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            "画面収録の許可が必要です。システム設定 > プライバシーとセキュリティ > 画面収録 で OtoLog を許可し、アプリを再起動してください。"
        }
    }
}
