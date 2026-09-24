import Foundation
@testable import OtoLogApp
import OtoLogCore
import Testing

/// 記録の経緯が後から追える形で残ることを守るテスト。
/// 失敗の理由はポップオーバーにしか出ず再起動で消えるため、ここが崩れると原因を追う手がかりが無くなる。
struct RecordingLogTests {
    // MARK: Internal

    // MARK: 出力先

    @Test func XDG_STATE_HOMEの下のotologのrecording_logへ書く() {
        let url = RecordingLog.resolveFileURL(stateHome: "/tmp/otolog-recording-test")
        #expect(url.path == "/tmp/otolog-recording-test/otolog/recording.log")
    }

    @Test func XDG未設定ならホーム配下のlocalstateに落とす() {
        let url = RecordingLog.resolveFileURL(stateHome: nil)
        #expect(url.path.hasSuffix(".local/state/otolog/recording.log"))
    }

    // MARK: 行の内容

    @Test func 開始要求は経路と入力と認識ロケールを残す() {
        let entry = RecordingLog.Entry.startRequested(
            via: .control, inputMode: .systemAndMicrophone, locales: ["en-US", "ja-JP"]
        )
        #expect(entry == RecordingLog.Entry(
            level: .info, message: "start requested: via=control input=systemAndMicrophone locales=en-US,ja-JP"
        ))
    }

    @Test func 状態遷移を残す() {
        #expect(RecordingLog.Entry(event: .stateChanged(.preparing))
            == RecordingLog.Entry(level: .info, message: "state: preparing"))
        #expect(RecordingLog.Entry(event: .stateChanged(.recording))
            == RecordingLog.Entry(level: .info, message: "state: recording"))
        #expect(RecordingLog.Entry(event: .stateChanged(.stopping))
            == RecordingLog.Entry(level: .info, message: "state: stopping"))
        #expect(RecordingLog.Entry(event: .stateChanged(.idle))
            == RecordingLog.Entry(level: .info, message: "state: idle"))
    }

    @Test func 失敗は理由つきのエラーとして残す() {
        let entry = RecordingLog.Entry(event: .stateChanged(.failed("マイク: デバイスが無効になりました")))
        #expect(entry == RecordingLog.Entry(level: .error, message: "state: failed: マイク: デバイスが無効になりました"))
    }

    @Test func 再起動するキャプチャ中断は音源と試行回数と理由を残す() {
        let entry = RecordingLog.Entry(event: .captureInterrupted(CaptureInterruption(
            source: .microphone, reason: "デバイスが無効になりました", restartAttempt: 1
        )))
        #expect(entry == RecordingLog.Entry(
            level: .error, message: "capture interrupted: マイク (restart 1): デバイスが無効になりました"
        ))
    }

    @Test func 再起動を諦めた中断はそれと分かるように残す() {
        let entry = RecordingLog.Entry(event: .captureInterrupted(CaptureInterruption(
            source: .system, reason: "capture stream ended unexpectedly", restartAttempt: nil
        )))
        #expect(entry == RecordingLog.Entry(
            level: .error, message: "capture interrupted: システム音声 (giving up): capture stream ended unexpectedly"
        ))
    }

    @Test func 保存と翻訳の失敗を残す() {
        #expect(RecordingLog.Entry(event: .storeError("書き込めません"))
            == RecordingLog.Entry(level: .error, message: "store error: 書き込めません"))
        #expect(RecordingLog.Entry(event: .translationError("訳せません"))
            == RecordingLog.Entry(level: .error, message: "translation error: 訳せません"))
    }

    /// 止めたのが利用者ではなく無音の見張りだったことと、何分の無音で止めたかを残す
    @Test func 無音での自動停止は無音の長さを残す() {
        #expect(RecordingLog.Entry(event: .autoStopped(silence: .seconds(30 * 60)))
            == RecordingLog.Entry(level: .info, message: "auto-stopped: silence for 30m"))
    }

    @Test func 分で割り切れない無音の長さは秒で残す() {
        #expect(RecordingLog.Entry(event: .autoStopped(silence: .seconds(90)))
            == RecordingLog.Entry(level: .info, message: "auto-stopped: silence for 90s"))
    }

    @Test func 完了したセッションはディレクトリ名を残す() {
        let ref = SessionRef(directoryName: "2026-09-16/1032", title: nil, startedAt: fixedDate)
        #expect(RecordingLog.Entry(event: .sessionFinished(ref))
            == RecordingLog.Entry(level: .info, message: "session finished: 2026-09-16/1032"))
    }

    /// 発話の本文は利用者の会話そのもので量も多い。準備の進捗は細かく流れるだけで経緯の手がかりにならない
    @Test func 発話の本文と準備の進捗は残さない() {
        let segment = TranscriptSegment(
            text: "確定した発話", audioStart: nil, audioEnd: nil, finalizedAt: fixedDate,
            locale: "ja-JP", source: .microphone, sessionID: UUID(), sessionStartedAt: fixedDate
        )
        #expect(RecordingLog.Entry(event: .liveTranscript("ライブの発話")) == nil)
        #expect(RecordingLog.Entry(event: .segmentRecorded(segment)) == nil)
        #expect(RecordingLog.Entry(event: .preparationProgress(0.5)) == nil)
    }

    // MARK: 書き込み

    @Test func 呼んだ順に呼んだ時点の時刻でファイルへ追記する() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "otolog/recording.log")
        let queue = DispatchQueue(label: "RecordingLogTests.append")
        let log = RecordingLog(fileURL: target, queue: queue)
        let later = fixedDate.addingTimeInterval(1)

        log.record(RecordingLog.Entry(level: .info, message: "state: recording"), at: fixedDate)
        log.record(RecordingLog.Entry(level: .error, message: "store error: 書き込めません"), at: later)
        queue.sync {}

        let contents = try String(contentsOf: target, encoding: .utf8)
        #expect(contents == StateLogFile.line(level: .info, message: "state: recording", at: fixedDate)
            + StateLogFile.line(level: .error, message: "store error: 書き込めません", at: later))
    }

    /// 書き込みは専用キューで行い、呼び出し元（MainActor と記録の経路）をファイル I/O で待たせない
    @Test(.timeLimit(.minutes(1))) func 書き込みが詰まっていても呼び出し元は待たされない() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "otolog/recording.log")
        let queue = DispatchQueue(label: "RecordingLogTests.blocked")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let log = RecordingLog(fileURL: target, queue: queue)

        log.record(RecordingLog.Entry(level: .info, message: "state: recording"))

        #expect(!FileManager.default.fileExists(atPath: target.path))
        gate.signal()
        queue.sync {}
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    // MARK: Private

    private let fixedDate = Date(timeIntervalSince1970: 1_789_000_000)

    private func makeTempRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "otolog-recording-log-\(UUID().uuidString)")
    }
}
