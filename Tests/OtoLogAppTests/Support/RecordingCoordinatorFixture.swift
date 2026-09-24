@preconcurrency import AVFAudio
import Foundation
@testable import OtoLogApp
import OtoLogCore

// MARK: - RecordingCoordinatorFixture

/// RecordingCoordinator を、実利用中の設定と recording.log に触れずに組み立てる。
/// 設定は専用の defaults に、保存先と recording.log は一時フォルダに向ける。
/// 記録は音声を流さないフィードで始まり、実デバイスと SpeechAnalyzer は使わない
@MainActor struct RecordingCoordinatorFixture {
    // MARK: Lifecycle

    init() {
        let suiteName = "OtoLogAppTests.recording-coordinator-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogAppTests-\(UUID().uuidString)", isDirectory: true)
        let logQueue = DispatchQueue(label: "OtoLogAppTests.recording-coordinator.log")
        let sleeps = SleepRecorder()
        settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        settings.saveDirectoryPath = root.appendingPathComponent("sessions", isDirectory: true).path
        state = AppState()
        session = RecordingSession(store: DiscardingTranscriptStore(), sleep: { try await sleeps.sleep(for: $0) })
        coordinator = RecordingCoordinator(
            session: session,
            store: SessionFileStore(directory: settings.saveDirectory, timeZone: .current),
            state: state,
            settings: settings,
            recordingLog: RecordingLog(fileURL: root.appendingPathComponent("recording.log"), queue: logQueue),
            makeFeeds: { _ in
                [RecordingFeed(capture: SilentCaptureSource(), engine: SilentTranscriptionEngine(), kind: .system)]
            }
        )
        self.sleeps = sleeps
        self.suiteName = suiteName
        self.root = root
        self.logQueue = logQueue
    }

    // MARK: Internal

    let state: AppState
    let settings: AppSettings
    let session: RecordingSession
    let coordinator: RecordingCoordinator
    /// 記録へ注入した sleep の呼び出し。音声を流さないフィードは中断しないため、残るのは無音の見張りの待ちだけ
    let sleeps: SleepRecorder

    /// 記録を止め、recording.log への書き込みを終えてから、専用の defaults を空にして一時フォルダを消す
    func tearDown() async {
        await session.stop()
        logQueue.sync {}
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Private

    private let suiteName: String
    private let root: URL
    private let logQueue: DispatchQueue
}

// MARK: - SleepRecorder

/// 記録へ注入する sleep。待とうとした長さを残し、待たずに取り消されたものとして抜ける。
/// 無音の見張りは最初の待ちで終わるため、時間を進めなくても空回りせず、記録はそのまま続く
final class SleepRecorder: @unchecked Sendable {
    // MARK: Internal

    var requestedDurations: [Duration] {
        lock.withLock { requested }
    }

    func sleep(for duration: Duration) async throws {
        lock.withLock { requested.append(duration) }
        throw CancellationError()
    }

    // MARK: Private

    private let lock = NSLock()
    private var requested: [Duration] = []
}

// MARK: - SilentCaptureSource

/// 音声を流さないキャプチャ。start から stop までチャンク列を開いたままにする
final class SilentCaptureSource: AudioCaptureSource, @unchecked Sendable {
    // MARK: Internal

    func start(targetFormat _: AVAudioFormat) async throws -> AsyncThrowingStream<AudioChunk, any Error> {
        let (stream, continuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func stop() async {
        lock.withLock { continuation }?.finish()
    }

    // MARK: Private

    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation?
}

// MARK: - SilentTranscriptionEngine

/// 結果を出さないエンジン。finish でイベント列を閉じる
final class SilentTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    // MARK: Internal

    func prepare(locales _: [Locale], onProgress _: @escaping @Sendable (Double) -> Void) async throws -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    }

    func start(
        chunks _: AsyncThrowingStream<AudioChunk, any Error>,
        context _: TranscriptionContext
    ) async throws -> AsyncThrowingStream<TranscriptEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, any Error>.makeStream()
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func finish() async {
        lock.withLock { continuation }?.finish()
    }

    // MARK: Private

    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<TranscriptEvent, any Error>.Continuation?
}

// MARK: - DiscardingTranscriptStore

/// 受け取ったものを捨てるストア。保存先を確保できたことにして記録を始めさせる
struct DiscardingTranscriptStore: TranscriptStore {
    func begin(context _: TranscriptionContext) async throws {}

    func append(_: TranscriptSegment) async throws {}

    func finalize(endedAt _: Date, reason _: SessionEndReason) async throws -> SessionRef? {
        nil
    }
}
