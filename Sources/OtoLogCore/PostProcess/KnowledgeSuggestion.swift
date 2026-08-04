import Foundation

// MARK: - SuggestionState

public enum SuggestionState: String, Sendable, Codable {
    case pending
    case dismissed
}

// MARK: - KnowledgeSuggestion

/// 確定前の前提知識候補。AI が出し、人が編集して確定させる。
public struct KnowledgeSuggestion: Sendable, Equatable, Codable, Identifiable {
    // MARK: Lifecycle

    public init(
        term: String,
        body: String,
        origin: String,
        createdAt: Date,
        state: SuggestionState = .pending
    ) {
        self.term = term
        self.body = body
        self.origin = origin
        self.createdAt = createdAt
        self.state = state
    }

    // MARK: Public

    public var term: String
    /// AI が書いた説明の下書き。確定前に人が直せる
    public var body: String
    /// どのセッション由来か。人が「何の話だったか」を思い出す手がかり
    public var origin: String
    public var createdAt: Date
    public var state: SuggestionState

    public var id: String {
        term
    }
}

// MARK: - KnowledgeSuggestionStore

/// 前提知識候補の置き場（<XDG_CONFIG_HOME>/otolog/knowledge-suggestions.json）。
///
/// 確定済みの前提知識は人が読む Markdown、候補は機械が管理する JSON と分けてある。
/// 候補の状態（却下したか）を Markdown に混ぜると、人が読む側が散らかるため。
public struct KnowledgeSuggestionStore: Sendable {
    // MARK: Lifecycle

    public init(fileURL: URL = KnowledgeSuggestionStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    // MARK: Public

    public static var defaultFileURL: URL {
        let environment = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let base = environment.flatMap { path in
            path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("otolog/knowledge-suggestions.json")
    }

    public func load() -> [KnowledgeSuggestion] {
        guard let data = try? Data(contentsOf: fileURL),
              let suggestions = try? decoder().decode([KnowledgeSuggestion].self, from: data)
        else { return [] }
        return suggestions
    }

    public func save(_ suggestions: [KnowledgeSuggestion]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            try container.encode(JSONLCoder.iso8601Millis(from: date))
        }
        try encoder.encode(suggestions).write(to: fileURL, options: .atomic)
    }

    /// 候補を確定させる。entry は人が編集したあとの内容で、提案の本文とは限らない
    public func accept(_ entry: KnowledgeEntry, into knowledge: KnowledgeStore) throws {
        try knowledge.append(entry)
        var suggestions = load()
        suggestions.removeAll { $0.term == entry.term }
        try save(suggestions)
    }

    /// 却下は記録として残す。消すだけだと次の走査でまた出てくる
    public func dismiss(term: String) throws {
        var suggestions = load()
        if let index = suggestions.firstIndex(where: { $0.term == term }) {
            suggestions[index].state = .dismissed
        }
        try save(suggestions)
    }

    public func isDismissed(_ term: String) -> Bool {
        load().contains { $0.term == term && $0.state == .dismissed }
    }

    // MARK: Private

    private let fileURL: URL

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = JSONLCoder.date(fromISO8601: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "invalid ISO8601 date: \(string)"
                )
            }
            return date
        }
        return decoder
    }
}
