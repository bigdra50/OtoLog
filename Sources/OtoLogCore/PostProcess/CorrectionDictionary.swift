import Foundation

// MARK: - CorrectionPair

/// 補正 diff から観測された1つの置換（誤認識 → 正しい表記）。
public struct CorrectionPair: Sendable, Equatable, Hashable {
    // MARK: Lifecycle

    public init(wrong: String, right: String) {
        self.wrong = wrong
        self.right = right
    }

    // MARK: Public

    public let wrong: String
    public let right: String
}

// MARK: - CorrectionEntry

public struct CorrectionEntry: Sendable, Equatable, Codable {
    // MARK: Lifecycle

    public init(wrong: String, right: String, count: Int, lastSeenAt: Date) {
        self.wrong = wrong
        self.right = right
        self.count = count
        self.lastSeenAt = lastSeenAt
    }

    // MARK: Public

    public var wrong: String
    public var right: String
    public var count: Int
    public var lastSeenAt: Date
}

// MARK: - CorrectionDictionary

/// 補正の実績から育つ修正辞書。Voyager のスキルライブラリと同型の
/// 「使うほど賢くなる」機構で、correct とタイトル生成のプロンプトへ注入される。
public struct CorrectionDictionary: Sendable, Equatable, Codable {
    // MARK: Lifecycle

    public init(schemaVersion: Int = 1, entries: [CorrectionEntry] = []) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    // MARK: Public

    public var schemaVersion: Int
    public var entries: [CorrectionEntry]

    /// プロンプト注入用のエントリ。複数回観測されたものだけを頻度順で返す
    /// （1回きりの修正は文脈依存の可能性があるため注入しない）
    public func promptEntries(minimumCount: Int = 2, limit: Int = 50) -> [CorrectionEntry] {
        entries
            .filter { $0.count >= minimumCount }
            .sorted { lhs, rhs in
                lhs.count != rhs.count ? lhs.count > rhs.count : lhs.wrong < rhs.wrong
            }
            .prefix(limit)
            .map(\.self)
    }
}

// MARK: - CorrectionDictionaryStore

/// 辞書の永続化（<XDG_CONFIG_HOME>/otolog/corrections.json）と、
/// 観測ペアの取り込み・監査（矛盾ペアの無効化・上限刈り込み）。
public struct CorrectionDictionaryStore: Sendable {
    // MARK: Lifecycle

    public init(fileURL: URL = CorrectionDictionaryStore.defaultFileURL, maxEntries: Int = 500) {
        self.fileURL = fileURL
        self.maxEntries = maxEntries
    }

    // MARK: Public

    public static var defaultFileURL: URL {
        let environment = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let base = environment.flatMap { path in
            path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("otolog/corrections.json")
    }

    /// 破損・欠損は空辞書（学習をやり直せば済む派生データのため）
    public func load() -> CorrectionDictionary {
        guard let data = try? Data(contentsOf: fileURL),
              let dictionary = try? decoder().decode(CorrectionDictionary.self, from: data)
        else { return CorrectionDictionary() }
        return dictionary
    }

    public func save(_ dictionary: CorrectionDictionary) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            try container.encode(JSONLCoder.iso8601Millis(from: date))
        }
        try encoder.encode(dictionary).write(to: fileURL, options: .atomic)
    }

    /// 観測ペアを取り込み、監査を適用して保存する。
    /// 監査: 逆向きペアが現れたら両方向を無効化（誤学習の混入防止）、上限超過は古い順に削除
    @discardableResult public func record(_ pairs: [CorrectionPair], now: Date) throws -> CorrectionDictionary {
        var dictionary = load()

        for pair in pairs {
            if let index = dictionary.entries.firstIndex(where: { $0.wrong == pair.wrong && $0.right == pair.right }) {
                dictionary.entries[index].count += 1
                dictionary.entries[index].lastSeenAt = now
            } else {
                dictionary.entries.append(
                    CorrectionEntry(wrong: pair.wrong, right: pair.right, count: 1, lastSeenAt: now)
                )
            }
        }

        // 矛盾監査: A→B と B→A が両方観測された語は信頼できない
        let keys = Set(dictionary.entries.map { CorrectionPair(wrong: $0.wrong, right: $0.right) })
        dictionary.entries.removeAll { entry in
            keys.contains(CorrectionPair(wrong: entry.right, right: entry.wrong))
        }

        if dictionary.entries.count > maxEntries {
            dictionary.entries = dictionary.entries
                .sorted { $0.lastSeenAt > $1.lastSeenAt }
                .prefix(maxEntries)
                .map(\.self)
        }

        try save(dictionary)
        return dictionary
    }

    // MARK: Private

    private let fileURL: URL
    private let maxEntries: Int

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
