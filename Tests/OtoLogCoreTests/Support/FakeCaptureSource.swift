@preconcurrency import AVFAudio
import Foundation
@testable import OtoLogCore

/// AudioCaptureSource のテストダブル。
/// initialChunks を start 時に流し、以降は emit/fail/stop でテストから制御する。
final class FakeCaptureSource: AudioCaptureSource, @unchecked Sendable {
    // MARK: Internal

    var initialChunks: [AudioChunk] = []
    /// start のたびに投げるエラー。startErrors が残っている間はそちらが先に投げられる
    var errorOnStart: (any Error)?
    /// 呼び出し順の検証用フック。onStart は start の先頭で待つので、start を途中で止めておくのにも使える
    var onStart: (@Sendable () async -> Void)?
    var onStop: (@Sendable () -> Void)?

    var startCallCount: Int {
        lock.withLock { _startCallCount }
    }

    var stopCallCount: Int {
        lock.withLock { _stopCallCount }
    }

    /// 最後に成功した start の後に stop されていない（キャプチャが動いたまま）
    var isCapturing: Bool {
        lock.withLock { _isCapturing }
    }

    var receivedTargetFormats: [AVAudioFormat] {
        lock.withLock { _receivedTargetFormats }
    }

    /// 次の start から1回に1つずつ順に投げるエラー。使い切ったら errorOnStart に戻る
    var startErrors: [any Error] {
        get { lock.withLock { queuedStartErrors } }
        set { lock.withLock { queuedStartErrors = newValue } }
    }

    func start(targetFormat: AVAudioFormat) async throws -> AsyncThrowingStream<AudioChunk, any Error> {
        await onStart?()
        let (stream, continuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        // 回数の記録とストリームの差し替えを同じロックで行う。startCallCount を見てから fail したテストが、
        // 差し替え前の終わったストリームを叩いて空振りしないようにするため
        let error: (any Error)? = lock.withLock {
            _startCallCount += 1
            _receivedTargetFormats.append(targetFormat)
            let error = queuedStartErrors.isEmpty ? errorOnStart : queuedStartErrors.removeFirst()
            if error == nil {
                self.continuation = continuation
                _isCapturing = true
            }
            return error
        }
        if let error { throw error }
        for chunk in initialChunks {
            continuation.yield(chunk)
        }
        return stream
    }

    func stop() async {
        lock.withLock {
            _stopCallCount += 1
            _isCapturing = false
        }
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
    private var queuedStartErrors: [any Error] = []
    private var _startCallCount = 0
    private var _stopCallCount = 0
    private var _receivedTargetFormats: [AVAudioFormat] = []
    private var _isCapturing = false

    private var currentContinuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation? {
        lock.withLock { continuation }
    }
}
