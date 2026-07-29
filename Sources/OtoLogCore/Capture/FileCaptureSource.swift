@preconcurrency import AVFAudio
import Foundation

/// 音声ファイルをチャンク列として流すキャプチャ源。統合テストとデバッグ用。
/// ファイル終端でストリームは正常 finish する。
public final class FileCaptureSource: AudioCaptureSource, @unchecked Sendable {
    // MARK: Lifecycle

    public init(url: URL, chunkFrames: AVAudioFrameCount = 4096) {
        self.url = url
        self.chunkFrames = chunkFrames
    }

    // MARK: Public

    public func start(targetFormat: AVAudioFormat) async throws -> AsyncThrowingStream<AudioChunk, any Error> {
        let file = try AVAudioFile(forReading: url)
        let (stream, continuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        let converter = BufferConverter()
        let chunkFrames = chunkFrames
        nonisolated(unsafe) let audioFile = file
        task = Task.detached {
            do {
                let sourceFormat = audioFile.processingFormat
                while !Task.isCancelled {
                    guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames) else {
                        break
                    }
                    try audioFile.read(into: input, frameCount: chunkFrames)
                    if input.frameLength == 0 { break }
                    if let output = converter.convert(input, to: targetFormat) {
                        continuation.yield(AudioChunk(buffer: output))
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    public func stop() async {
        task?.cancel()
    }

    // MARK: Private

    private let url: URL
    private let chunkFrames: AVAudioFrameCount
    private var task: Task<Void, Never>?
}
