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

    typealias Level = LogLevel

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
        StateLogFile.url(named: "ui.log", stateHome: stateHome)
    }

    static func line(level: Level, message: String, at date: Date) -> String {
        StateLogFile.line(level: level, message: message, at: date)
    }

    @discardableResult static func write(level: Level, message: String, to url: URL, at date: Date = Date()) -> Bool {
        StateLogFile.append(level: level, message: message, to: url, at: date)
    }

    // MARK: Private

    private static let logger = Logger(subsystem: "com.bigdra50.OtoLog", category: "ui")
}
