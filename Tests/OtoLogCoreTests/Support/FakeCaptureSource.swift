@preconcurrency import AVFAudio
import Foundation
@testable import OtoLogCore

/// AudioCaptureSource のテストダブル。
/// initialChunks を start 時に流し、以降は emit/fail/stop でテストから制御する。
final class FakeCaptureSource: AudioCaptureSource, @unchecked Sendable {
    // MARK: Internal

    var initialChunks: [AudioChunk] = []
    var errorOnStart: (any Error)?
    /// 呼び出し順の検証用フック
    var onStop: (@Sendable () -> Void)?

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var receivedTargetFormats: [AVAudioFormat] = []

    func start(targetFormat: AVAudioFormat) async throws -> AsyncThrowingStream<AudioChunk, any Error> {
        lock.withLock {
            startCallCount += 1
            receivedTargetFormats.append(targetFormat)
        }
        if let errorOnStart { throw errorOnStart }
        let (stream, continuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        lock.withLock { self.continuation = continuation }
        for chunk in initialChunks {
            continuation.yield(chunk)
        }
        return stream
    }

    func stop() async {
        lock.withLock { stopCallCount += 1 }
        onStop?()
        currentContinuation?.finish()
    }

    func emit(_ chunk: AudioChunk) {
        currentContinuation?.yield(chunk)
    }

    func fail(_ error: any Error) {
        currentContinuation?.finish(throwing: error)
    }

    // MARK: Private

    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation?

    private var currentContinuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation? {
        lock.withLock { continuation }
    }
}
