import Foundation

/// 記録セッションのディレクトリ名を決める。
/// 現行構造は日付フォルダ階層 <yyyy-MM-dd>/<タイトル or HHmm>（相対パス）で、
/// 旧フラット構造 <yyyy-MM-dd_HHmm>[_<タイトル>] の読み取りにも対応する。
/// タイトルはファイルシステムに安全な形へ正規化してから使う。
public struct SessionDirectoryNamer: Sendable {
    // MARK: Lifecycle

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    // MARK: Public

    /// パス区切り・シェル特殊文字・空白をハイフンへ、制御文字は除去。
    /// 連続ハイフンは圧縮し前後をトリム。結果が空なら nil（タイトルなし扱い）
    public static func sanitizeTitle(_ title: String, maxLength: Int = 40) -> String? {
        var result = title
        for character in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"] {
            result = result.replacingOccurrences(of: character, with: "-")
        }
        result = result.components(separatedBy: .controlCharacters).joined()
        result = result.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        let hyphens = CharacterSet(charactersIn: "-")
        result = result.trimmingCharacters(in: hyphens)
        result = String(result.prefix(maxLength)).trimmingCharacters(in: hyphens)
        return result.isEmpty ? nil : result
    }

    public func baseName(for date: Date) -> String {
        // DateFormatter は Sendable でないため保持せず毎回生成する（DailyFileNamer と同じ流儀）
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return formatter.string(from: date)
    }

    public func directoryName(startedAt: Date, title: String?) -> String {
        let base = baseName(for: startedAt)
        guard let title, let sanitized = Self.sanitizeTitle(title) else { return base }
        return "\(base)_\(sanitized)"
    }

    public func dateComponent(for date: Date) -> String {
        formatted(date, format: "yyyy-MM-dd")
    }

    public func timeComponent(for date: Date) -> String {
        formatted(date, format: "HHmm")
    }

    /// 日付フォルダ階層の相対パス。タイトル未定なら時刻名（例 2026-07-29/1300）
    public func relativePath(startedAt: Date, title: String?) -> String {
        let name = title.flatMap { Self.sanitizeTitle($0) } ?? timeComponent(for: startedAt)
        return "\(dateComponent(for: startedAt))/\(name)"
    }

    /// 新旧両形式の相対パスから開始時刻を復元する（meta 破損時のフォールバック）。
    /// 新構造でタイトル名の場合は日付のみ（その日の0時）
    public func parseStartedAt(fromRelativePath path: String) -> Date? {
        // 新構造: <yyyy-MM-dd>/<HHmm[-n] or タイトル>
        if let match = path.wholeMatch(of: /(\d{4}-\d{2}-\d{2})\/(.+)/) {
            let date = String(match.output.1)
            let child = String(match.output.2)
            if let timeMatch = child.prefixMatch(of: /\d{4}/),
               let parsed = parse("\(date)_\(timeMatch.output)", format: "yyyy-MM-dd_HHmm") {
                return parsed
            }
            return parse(date, format: "yyyy-MM-dd")
        }
        // 旧フラット構造: <yyyy-MM-dd_HHmm>...
        if let match = path.prefixMatch(of: /\d{4}-\d{2}-\d{2}_\d{4}/) {
            return parse(String(match.output), format: "yyyy-MM-dd_HHmm")
        }
        return nil
    }

    // MARK: Private

    private let timeZone: TimeZone

    private func formatted(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private func parse(_ string: String, format: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.date(from: string)
    }
}
