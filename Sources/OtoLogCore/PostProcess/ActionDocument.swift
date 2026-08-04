import Foundation

// MARK: - ActionDocument

/// アクションアイテムの構造化出力。
///
/// 完了したかを機械が追い、外部へ書き出す対象なので型を固定する。
/// 型にはめると死ぬニュアンス（進みが遅い、先方の温度感など）は現況メモの担当。
public struct ActionDocument: Sendable, Equatable, Codable {
    // MARK: Lifecycle

    public init(actions: [Action]) {
        self.actions = actions
    }

    public init(json: String) throws {
        self = try JSONDecoder().decode(ActionDocument.self, from: Data(Self.stripCodeFence(json).utf8))
    }

    // MARK: Public

    public struct Action: Sendable, Equatable, Codable {
        // MARK: Lifecycle

        public init(
            task: String,
            owner: String? = nil,
            due: String? = nil,
            at: String? = nil,
            decided: Bool = false
        ) {
            self.task = task
            self.owner = owner
            self.due = due
            self.at = at
            self.decided = decided
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            task = try container.decode(String.self, forKey: .task)
            owner = try container.decodeIfPresent(String.self, forKey: .owner)
            due = try container.decodeIfPresent(String.self, forKey: .due)
            at = try container.decodeIfPresent(String.self, forKey: .at)
            decided = try container.decodeIfPresent(Bool.self, forKey: .decided) ?? false
        }

        // MARK: Public

        public let task: String
        /// ログで言及があったときだけ入る。埋めさせない
        public let owner: String?
        public let due: String?
        /// 発言時刻。記録のどこで決まったかを辿れるようにする
        public let at: String?
        /// 決定に基づくものか、提案止まりか。
        /// 欠けていたら提案として扱う（決定と誤って断じるより安全）
        public let decided: Bool
    }

    public let actions: [Action]

    // MARK: Private

    private static func stripCodeFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        lines.removeFirst()
        if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

// MARK: - ActionFormatter

/// 構造化出力から人が読む Markdown を組み立てる。
public enum ActionFormatter {
    // MARK: Public

    public static func markdown(from document: ActionDocument) -> String {
        guard !document.actions.isEmpty else {
            return "アクションアイテムは記録されていません。\n"
        }
        var sections: [String] = []
        let decided = document.actions.filter(\.decided)
        let proposed = document.actions.filter { !$0.decided }
        if !decided.isEmpty {
            sections.append("## 決定事項\n" + decided.map(line(for:)).joined())
        }
        if !proposed.isEmpty {
            sections.append("## 提案・検討中\n" + proposed.map(line(for:)).joined())
        }
        return sections.joined(separator: "\n")
    }

    // MARK: Private

    private static func line(for action: ActionDocument.Action) -> String {
        var line = "- [ ] \(action.task)"
        let notes = [action.owner, action.due, action.at].compactMap(\.self)
        if !notes.isEmpty {
            line += "（\(notes.joined(separator: " / "))）"
        }
        return line + "\n"
    }
}
