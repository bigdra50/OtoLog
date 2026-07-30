import Foundation

/// 確定セグメントを日次 Markdown の行へ整形する。
/// 日付→stem の計算は DailyFileNamer の責務なので、ここでは受け取った stem をそのまま使う。
public struct MarkdownFormatter: Sendable {
    // MARK: Lifecycle

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    // MARK: Public

    public func header(forStem stem: String) -> String {
        "# \(stem)\n\n"
    }

    /// 1セグメント1行を守るため改行と連続空白は空白1個に潰す。空になったら nil（書かない）。
    /// 訳があるときは原文の子行として続ける（原文を正本に残したまま訳を読めるようにする）
    public func line(for segment: TranscriptSegment) -> String? {
        guard let squashed = Self.squash(segment.text) else { return nil }
        var line = "- **\(timeString(from: segment.finalizedAt))** \(squashed)\n"
        if let translation = segment.translation.flatMap(Self.squash) {
            line += "  - \(translation)\n"
        }
        return line
    }

    // MARK: Private

    private let timeZone: TimeZone

    private static func squash(_ text: String) -> String? {
        let squashed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return squashed.isEmpty ? nil : squashed
    }

    /// DateFormatter は Sendable でないため共有せず毎回生成する
    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
