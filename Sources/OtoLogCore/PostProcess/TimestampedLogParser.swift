import Foundation

/// 「[HH:mm:ss] 本文」形式の行ログ（correct テンプレート等の出力）を構造化する。
/// すべての非空行がこの形式のときだけ成功し、混在文書は nil（通常の Markdown として扱う）。
public enum TimestampedLogParser {
    public struct Line: Sendable, Equatable {
        // MARK: Lifecycle

        public init(time: String, text: String) {
            self.time = time
            self.text = text
        }

        // MARK: Public

        public let time: String
        public let text: String
    }

    public static func parse(_ contents: String) -> [Line]? {
        var lines: [Line] = []
        for raw in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let match = trimmed.wholeMatch(of: /\[(\d{2}:\d{2}:\d{2})\]\s*(.*)/) else { return nil }
            lines.append(Line(time: String(match.output.1), text: String(match.output.2)))
        }
        return lines.isEmpty ? nil : lines
    }
}
