import Foundation

// MARK: - LogLevel

/// テキストログの重要度。行の `[INFO]` などにそのまま出る
enum LogLevel: String {
    case info = "INFO"
    /// 処理の失敗。記録の中断や保存の失敗など
    case error = "ERROR"
    /// 起きてはいけない状態。ポップオーバーのはみ出しなど
    case fault = "FAULT"
}

// MARK: - StateLogFile

/// XDG_STATE_HOME/otolog/ 配下のテキストログ（ui.log・recording.log）の書き出し。
///
/// 統合ログは10日ほどで消えるため、再起動やログ回転をまたいで残す控えとして使う。
/// 書式と追記の手順を1か所にまとめ、ログごとに grep の仕方が変わらないようにする
enum StateLogFile {
    // MARK: Internal

    /// 出力先の解決。stateHome が空なら ~/.local/state に落とす
    static func url(named name: String, stateHome: String?) -> URL {
        let base: URL = if let stateHome, !stateHome.isEmpty {
            URL(fileURLWithPath: (stateHome as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/state", isDirectory: true)
        }
        return base
            .appendingPathComponent("otolog", isDirectory: true)
            .appendingPathComponent(name)
    }

    /// 1行を組み立てる。書式を固定して後から grep できるようにする
    static func line(level: LogLevel, message: String, at date: Date) -> String {
        "\(timestampFormatter.string(from: date)) [\(level.rawValue)] \(message)\n"
    }

    /// 追記する。診断機能なので失敗しても本処理は止めない
    @discardableResult static func append(
        level: LogLevel, message: String, to url: URL, at date: Date = Date()
    ) -> Bool {
        guard let data = line(level: level, message: message, at: date).data(using: .utf8) else {
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: Private

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }()
}
