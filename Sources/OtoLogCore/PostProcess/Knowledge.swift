import Foundation

// MARK: - KnowledgeEntry

/// 固有名詞1件ぶんの知識。用語と、それが何者かの説明。
public struct KnowledgeEntry: Sendable, Equatable, Identifiable {
    // MARK: Lifecycle

    public init(term: String, body: String) {
        self.term = term
        self.body = body
    }

    // MARK: Public

    public let term: String
    public let body: String

    public var id: String {
        term
    }
}

// MARK: - KnowledgeParser

/// 前提知識の Markdown をエントリへ変換する。
///
/// 「誤り → 正しい表記」の置換ペアでは粒度が粗すぎる。断片的な置換は文脈を選ばず当たり、
/// かといって語を並べるだけでは何者か分からず、音が近いだけの箇所まで引き寄せる。
/// 何であるかを添えて初めて、文脈の合う箇所だけを直せる。
///
/// 形式は生成物の glossary.md と同じ「## 用語 + 本文」。生成された用語集をそのまま貼れる。
public enum KnowledgeParser {
    // MARK: Public

    /// `##` が用語、その下はすべて本文。
    /// `###` は本文の一部として残す（「### 定義」のような節を用語と取り違えないため）。
    /// 生成物の用語集は分類で階層化されることがあるが、その解釈は GlossaryMarkdownParser の役目
    public static func entries(from markdown: String) -> [KnowledgeEntry] {
        sections(in: markdown, level: 2).compactMap(entry(from:))
    }

    // MARK: Internal

    struct Section {
        let title: String
        let body: String
    }

    /// 指定した見出しレベルで区切る。より浅い見出し（# や ##）は区切りとしてだけ扱う
    static func sections(in markdown: String, level: Int) -> [Section] {
        let marker = String(repeating: "#", count: level) + " "
        let shallower = (1..<level).map { String(repeating: "#", count: $0) + " " }
        var sections: [Section] = []
        var title: String?
        var body: [String] = []

        func flush() {
            guard let title else { return }
            sections.append(Section(title: title, body: body.joined(separator: "\n")))
            body = []
        }

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(marker) {
                flush()
                title = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            } else if shallower.contains(where: trimmed.hasPrefix) {
                flush()
                title = nil
            } else if title != nil {
                body.append(line)
            }
        }
        flush()
        return sections
    }

    /// 本文の無い見出しは分類のためのもので、知識ではない
    static func entry(from section: Section) -> KnowledgeEntry? {
        let text = section.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return KnowledgeEntry(term: section.title, body: text)
    }
}

// MARK: - KnowledgeStore

/// 前提知識の置き場（<XDG_CONFIG_HOME>/otolog/knowledge.md）。
/// 人が直接書き足す前提なので Markdown にしてある（git に置いてチームで共有できる）。
public struct KnowledgeStore: Sendable {
    // MARK: Lifecycle

    public init(fileURL: URL = KnowledgeStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    // MARK: Public

    public static var defaultFileURL: URL {
        let environment = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let base = environment.flatMap { path in
            path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("otolog/knowledge.md")
    }

    /// 未作成でも空を返す。置かなければ従来どおり動く
    public func load() -> [KnowledgeEntry] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return KnowledgeParser.entries(from: text)
    }

    /// 確定したエントリを末尾へ足す。人が書いた既存の記述には触らない
    public func append(_ entry: KnowledgeEntry) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let section = "## \(entry.term)\n\(entry.body)\n"
        let separator = existing.isEmpty || existing.hasSuffix("\n\n") ? "" : "\n"
        try (existing + separator + section).write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: Private

    private let fileURL: URL
}
