@preconcurrency import AVFAudio
import Foundation
@testable import OtoLogCore

/// TranscriptionEngine のテストダブル。
/// chunks は内部 Task で消費してカウントし、イベントは send/failEvents/finishEvents で流す。
final class FakeTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    // MARK: Internal

    var prepareError: (any Error)?
    var prepareFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    var progressScript: [Double] = []
    /// 呼び出し順の検証用フック
    var onFinish: (@Sendable () -> Void)?

    var prepareCallCount: Int {
        lock.withLock { _prepareCallCount }
    }

    var finishCallCount: Int {
        lock.withLock { _finishCallCount }
    }

    var consumedChunkCount: Int {
        lock.withLock { _consumedChunkCount }
    }

    var receivedContexts: [TranscriptionContext] {
        lock.withLock { _receivedContexts }
    }

    func prepare(locale _: Locale, onProgress: @escaping @Sendable (Double) -> Void) async throws -> AVAudioFormat {
        lock.withLock { _prepareCallCount += 1 }
        if let prepareError { throw prepareError }
        for progress in progressScript {
            onProgress(progress)
        }
        return prepareFormat
    }

    func start(
        chunks: AsyncThrowingStream<AudioChunk, any Error>,
        context: TranscriptionContext
    ) async throws -> AsyncThrowingStream<TranscriptEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, any Error>.makeStream()
        lock.withLock {
            eventContinuation = continuation
            _receivedContexts.append(context)
        }
        Task { [weak self] in
            // 実エンジン同様、チャンクエラーでイベント列は落とさない（finish 側で閉じる）
            do {
                for try await _ in chunks {
                    self?.incrementConsumedChunk()
                }
            } catch {}
        }
        return stream
    }

    func finish() async {
        lock.withLock { _finishCallCount += 1 }
        onFinish?()
        currentEventContinuation?.finish()
    }

    func send(_ event: TranscriptEvent) {
        currentEventContinuation?.yield(event)
    }

    func failEvents(_ error: any Error) {
        currentEventContinuation?.finish(throwing: error)
    }

    func finishEvents() {
        currentEventContinuation?.finish()
    }

    // MARK: Private

    private let lock = NSLock()
    private var eventContinuation: AsyncThrowingStream<TranscriptEvent, any Error>.Continuation?
    private var _prepareCallCount = 0
    private var _finishCallCount = 0
    private var _consumedChunkCount = 0
    private var _receivedContexts: [TranscriptionContext] = []

    private var currentEventContinuation: AsyncThrowingStream<TranscriptEvent, any Error>.Continuation? {
        lock.withLock { eventContinuation }
    }

    private func incrementConsumedChunk() {
        lock.withLock { _consumedChunkCount += 1 }
    }
}
