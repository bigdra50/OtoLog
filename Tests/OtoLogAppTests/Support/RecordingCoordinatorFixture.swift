import Foundation
@testable import OtoLogApp
import OtoLogCore

/// RecordingCoordinator を、実利用中の設定と recording.log に触れずに組み立てる。
/// 設定は専用の defaults に、保存先と recording.log は一時フォルダに向ける
@MainActor struct RecordingCoordinatorFixture {
    // MARK: Lifecycle

    init() {
        let suiteName = "OtoLogAppTests.recording-coordinator-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogAppTests-\(UUID().uuidString)", isDirectory: true)
        let logQueue = DispatchQueue(label: "OtoLogAppTests.recording-coordinator.log")
        settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        settings.saveDirectoryPath = root.appendingPathComponent("sessions", isDirectory: true).path
        state = AppState()
        session = RecordingSession(store: IdleTranscriptStore())
        coordinator = RecordingCoordinator(
            session: session,
            store: SessionFileStore(directory: settings.saveDirectory, timeZone: .current),
            state: state,
            settings: settings,
            recordingLog: RecordingLog(fileURL: root.appendingPathComponent("recording.log"), queue: logQueue)
        )
        self.suiteName = suiteName
        self.root = root
        self.logQueue = logQueue
    }

    // MARK: Internal

    let state: AppState
    let settings: AppSettings
    let session: RecordingSession
    let coordinator: RecordingCoordinator

    /// 記録を止め、recording.log への書き込みを終えてから、専用の defaults と一時フォルダを消す
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
