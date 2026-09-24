import Foundation
import os
import OtoLogCore

/// 記録の経緯を後から追えるようにする記録。
///
/// 記録の失敗はポップオーバーにしか出ず、アプリを再起動すると消える。
/// どの音源がいつ・なぜ止まったかを残すため、開始要求・状態遷移・キャプチャの中断・
/// 保存と翻訳の失敗・完了したセッションを、統合ログ（category recording）と
/// XDG_STATE_HOME/otolog/recording.log の両方へ出す。
/// 前者は log stream で追いやすく、後者は統合ログが消えた後も残る。
struct RecordingLog {
    // MARK: Lifecycle

    /// queue はファイルへの追記を直列に流す先。テストは渡したキューを sync して書き込みの完了を待つ
    init(
        fileURL: URL = RecordingLog.resolveFileURL(stateHome: ProcessInfo.processInfo.environment["XDG_STATE_HOME"]),
        queue: DispatchQueue = DispatchQueue(label: "com.bigdra50.OtoLog.recording-log", qos: .utility)
    ) {
        self.fileURL = fileURL
        self.queue = queue
    }

    // MARK: Internal

    /// 開始要求の経路。UI 操作とエージェント（制御ソケット）のどちらから始めたかを見分ける
    enum StartOrigin: String {
        case popover
        case control
    }

    /// ログ1行ぶんの内容。時刻は record を呼んだ時点で付く
    struct Entry: Equatable {
        // MARK: Lifecycle

        init(level: LogLevel, message: String) {
            self.level = level
            self.message = message
        }

        /// 経緯に関わるイベントだけを行にする。ライブ字幕と確定セグメントは利用者の発話そのもので量も多く、
        /// 準備の進捗は細かく流れるだけで経緯の手がかりにならないため nil を返す
        init?(event: SessionEvent) {
            switch event {
            case .stateChanged(.idle):
                self.init(level: .info, message: "state: idle")
            case .stateChanged(.preparing):
                self.init(level: .info, message: "state: preparing")
            case .stateChanged(.recording):
                self.init(level: .info, message: "state: recording")
            case .stateChanged(.stopping):
                self.init(level: .info, message: "state: stopping")
            case let .stateChanged(.failed(reason)):
                self.init(level: .error, message: "state: failed: \(reason)")
            case let .captureInterrupted(interruption):
                let decision = interruption.restartAttempt.map { "restart \($0)" } ?? "giving up"
                self.init(
                    level: .error,
                    message: "capture interrupted: \(interruption.source.displayName) (\(decision)): \(interruption.reason)"
                )
            case let .storeError(message):
                self.init(level: .error, message: "store error: \(message)")
            case let .translationError(message):
                self.init(level: .error, message: "translation error: \(message)")
            case let .sessionFinished(ref):
                self.init(level: .info, message: "session finished: \(ref.directoryName)")
            case .preparationProgress, .liveTranscript, .segmentRecorded:
                return nil
            }
        }

        // MARK: Internal

        let level: LogLevel
        let message: String

        /// どの入力とロケールで始めようとしたか。失敗が設定の組み合わせに由来するかを切り分けるため
        static func startRequested(via origin: StartOrigin, inputMode: AudioInputMode, locales: [String]) -> Entry {
            Entry(
                level: .info,
                message: "start requested: via=\(origin.rawValue) input=\(inputMode.rawValue) "
                    + "locales=\(locales.joined(separator: ","))"
            )
        }
    }

    /// 出力先の解決。stateHome が空なら ~/.local/state に落とす
    static func resolveFileURL(stateHome: String?) -> URL {
        StateLogFile.url(named: "recording.log", stateHome: stateHome)
    }

    /// 統合ログへ出し、ファイルへの追記は専用キューへ回す。
    /// 呼び出し元は MainActor と記録の経路なので、XDG_STATE_HOME が遅いボリュームにあってもファイル I/O で待たせない。
    /// 追記の失敗は StateLogFile が握るため、記録へ例外は届かない
    func record(_ entry: Entry, at date: Date = Date()) {
        switch entry.level {
        // info は既定で統合ログのストアへ移らず、後から log show で引けないため notice で出す
        case .info: Self.logger.notice("\(entry.message, privacy: .public)")
        case .error: Self.logger.error("\(entry.message, privacy: .public)")
        case .fault: Self.logger.fault("\(entry.message, privacy: .public)")
        }
        let fileURL = fileURL
        queue.async {
            StateLogFile.append(level: entry.level, message: entry.message, to: fileURL, at: date)
        }
    }

    // MARK: Private

    private static let logger = Logger(subsystem: "com.bigdra50.OtoLog", category: "recording")

    private let fileURL: URL
    private let queue: DispatchQueue
}
