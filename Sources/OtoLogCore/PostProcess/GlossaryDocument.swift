import Foundation

// MARK: - GlossaryDocument

/// 用語集の構造化出力。
///
/// Markdown を書かせてパースすると、分類見出しを用語として拾うような取りこぼしが起きる。
/// 機械が使う正本は JSON にし、人が読む md はそこから組み立てる
/// （transcript.jsonl と transcript.md の関係と同じ）。
public struct GlossaryDocument: Sendable, Equatable, Codable {
    // MARK: Lifecycle

    public init(terms: [Term]) {
        self.terms = terms
    }

    /// 生成結果の文字列から読む。指示に反してコードフェンスで包まれても読めるようにする
    public init(json: String) throws {
        let trimmed = Self.stripCodeFence(json)
        self = try JSONDecoder().decode(GlossaryDocument.self, from: Data(trimmed.utf8))
    }

    // MARK: Public

    public struct Term: Sendable, Equatable, Codable {
        // MARK: Lifecycle

        public init(term: String, context: String, definition: String, reference: String? = nil) {
            self.term = term
            self.context = context
            self.definition = definition
            self.reference = reference
        }

        // MARK: Public

        public let term: String
        /// ログ内でどう使われたか
        public let context: String
        /// 一般的な定義。前提知識として持ち回るのはこちら
        public let definition: String
        public let reference: String?
    }

    public let terms: [Term]

    /// 前提知識の候補。本文は定義だけにする（文脈まで入れるとプロンプトが膨らむ）
    public func knowledgeEntries() -> [KnowledgeEntry] {
        terms.map { KnowledgeEntry(term: $0.term, body: $0.definition) }
    }

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

// MARK: - GlossaryFormatter

/// 構造化出力から人が読む Markdown を組み立てる。
/// 体裁を OtoLog 側で固定するので、前提知識のパーサーが確実に読める。
public enum GlossaryFormatter {
    public static func markdown(from document: GlossaryDocument) -> String {
        document.terms
            .map { term in
                var section = "## \(term.term)\n\n### ログ内の文脈\n\(term.context)\n\n### 定義\n\(term.definition)\n"
                if let reference = term.reference, !reference.isEmpty {
                    section += "\n出典: \(reference)\n"
                }
                return section
            }
            .joined(separator: "\n")
    }
}
