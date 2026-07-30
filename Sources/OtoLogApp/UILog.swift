import Foundation
import os

/// UI の異常を後から追えるようにする記録。
///
/// 崩れは再現性が低く、起きた瞬間にしか値が取れないため常時記録する。
/// 統合ログ（`log show --predicate 'subsystem == "com.bigdra50.OtoLog"'`）と、
/// XDG_STATE_HOME/otolog/ui.log の両方へ出す。
/// 前者は取り回しがよく、後者は再起動やログ回転をまたいで残る。
enum UILog {
    // MARK: Internal

    enum Level: String {
        case info = "INFO"
        /// 起きてはいけない状態。ポップオーバーのはみ出しなど
        case fault = "FAULT"
    }

    /// 追記先。XDG_STATE_HOME に従う
    static var fileURL: URL {
        resolveFileURL(stateHome: ProcessInfo.processInfo.environment["XDG_STATE_HOME"])
    }

    /// 平常時の記録。量が増えないよう操作の節目にとどめる
    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write(level: .info, message: message, to: fileURL)
    }

    static func fault(_ message: String) {
        logger.fault("\(message, privacy: .public)")
        write(level: .fault, message: message, to: fileURL)
    }

    /// 出力先の解決。stateHome が空なら ~/.local/state に落とす
    static func resolveFileURL(stateHome: String?) -> URL {
        let base: URL = if let stateHome, !stateHome.isEmpty {
            URL(fileURLWithPath: (stateHome as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/state", isDirectory: true)
        }
        return base
            .appendingPathComponent("otolog", isDirectory: true)
            .appendingPathComponent("ui.log")
    }

    /// 1行を組み立てる。書式を固定して後から grep できるようにする
    static func line(level: Level, message: String, at date: Date) -> String {
        "\(timestampFormatter.string(from: date)) [\(level.rawValue)] \(message)\n"
    }

    /// 追記する。診断機能なので失敗しても本処理は止めない
    @discardableResult static func write(level: Level, message: String, to url: URL, at date: Date = Date()) -> Bool {
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

    private static let logger = Logger(subsystem: "com.bigdra50.OtoLog", category: "ui")

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }()
}
