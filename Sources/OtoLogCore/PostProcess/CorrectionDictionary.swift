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

// MARK: - CorrectionReview

/// 人によるチェックの状態。未チェックでも補正には使う（初回から効かせるため）。
public enum CorrectionReview: String, Sendable, Codable, CaseIterable {
    case unreviewed
    case confirmed
    case rejected
}

// MARK: - CorrectionEntry

public struct CorrectionEntry: Sendable, Equatable, Codable {
    // MARK: Lifecycle

    public init(
        wrong: String,
        right: String,
        count: Int,
        firstSeenAt: Date,
        lastSeenAt: Date,
        review: CorrectionReview = .unreviewed,
        reviewedAt: Date? = nil
    ) {
        self.wrong = wrong
        self.right = right
        self.count = count
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.review = review
        self.reviewedAt = reviewedAt
    }

    /// review と firstSeenAt が入る前に書かれた辞書も読めるようにする。
    /// 既存の学習を捨てずに済ませるため、欠けている項目は既定へ寄せる
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wrong = try container.decode(String.self, forKey: .wrong)
        right = try container.decode(String.self, forKey: .right)
        count = try container.decode(Int.self, forKey: .count)
        lastSeenAt = try container.decode(Date.self, forKey: .lastSeenAt)
        // 初出が不明なので最終観測に寄せる。生存期間は 0 から数え直しになる
        firstSeenAt = try container.decodeIfPresent(Date.self, forKey: .firstSeenAt) ?? lastSeenAt
        review = try container.decodeIfPresent(CorrectionReview.self, forKey: .review) ?? .unreviewed
        reviewedAt = try container.decodeIfPresent(Date.self, forKey: .reviewedAt)
    }

    // MARK: Public

    public var wrong: String
    public var right: String
    public var count: Int
    /// 生存期間の起点。長く残っているほど「否定されなかった」ことの裏づけになる
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var review: CorrectionReview
    public var reviewedAt: Date?

    /// 補正へ効かせてよい度合い（0...1）。
    ///
    /// 人が確認したものは 1、否定したものは 0。未チェックは 0.3 から始まり、
    /// 観測回数と生存期間で上がるが確認済みには追いつかない。
    /// 「はっきり突っ込まれていないから、たぶん間違いではない」を数値にしたもの
    public func confidence(asOf now: Date) -> Double {
        switch review {
        case .confirmed: 1.0
        case .rejected: 0
        case .unreviewed:
            min(
                Self.unreviewedCeiling,
                Self.unreviewedBase + observationBonus + survivalBonus(asOf: now)
            )
        }
    }

    // MARK: Private

    private static let unreviewedBase = 0.3
    private static let unreviewedCeiling = 0.8

    /// 何度も同じ直され方をしているほど確からしい。効きは対数で頭打ちにする
    private var observationBonus: Double {
        min(0.3, 0.1 * log2(Double(max(count, 1))))
    }

    /// 10 週生き延びれば上限。それ以上は回数で差をつける
    private func survivalBonus(asOf now: Date) -> Double {
        let weeks = max(0, now.timeIntervalSince(firstSeenAt)) / (7 * 24 * 60 * 60)
        return min(0.2, 0.02 * weeks)
    }
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

    /// プロンプト注入用のエントリ。信頼度の高い順に返す。
    /// 既定の閾値は「未チェックで2回観測」に相当し、人が否定したものは必ず外れる
    public func promptEntries(
        minimumConfidence: Double = 0.4,
        limit: Int = 50,
        asOf now: Date = Date()
    ) -> [CorrectionEntry] {
        let scored: [(entry: CorrectionEntry, confidence: Double)] = entries
            .map { (entry: $0, confidence: $0.confidence(asOf: now)) }
            .filter { $0.confidence >= minimumConfidence }
        let ordered = scored.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            return lhs.entry.wrong < rhs.entry.wrong
        }
        return ordered.prefix(limit).map(\.entry)
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

    /// 破損・欠損は空辞書（学習をやり直せば済む派生データのため）。
    ///
    /// 読み込み時に現在の基準で濾す。基準を厳しくする前に貯まったエントリ
    /// （「ご→誤」のような1文字ペア）が残っていると、信頼度を計算しても
    /// 観測回数だけは多いので上位に居座り続ける
    public func load() -> CorrectionDictionary {
        guard let data = try? Data(contentsOf: fileURL),
              var dictionary = try? decoder().decode(CorrectionDictionary.self, from: data)
        else { return CorrectionDictionary() }
        dictionary.entries.removeAll { entry in
            CorrectionPair(text: entry.wrong, replacement: entry.right) == nil
        }
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
                    CorrectionEntry(
                        wrong: pair.wrong, right: pair.right, count: 1,
                        firstSeenAt: now, lastSeenAt: now
                    )
                )
            }
        }

        // 矛盾監査: A→B と B→A が両方観測された語は信頼できない
        let keys = Set(dictionary.entries.map { CorrectionPair(wrong: $0.wrong, right: $0.right) })
        dictionary.entries.removeAll { entry in
            keys.contains(CorrectionPair(wrong: entry.right, right: entry.wrong))
        }

        if dictionary.entries.count > maxEntries {
            // 人が判断した分は残す。自動で貯まったものから古い順に捨てる。
            // 却下を捨てると、同じ誤りを観測したときに未チェックとして戻ってきてしまう
            let reviewed = dictionary.entries.filter { $0.review != .unreviewed }
            let unreviewed = dictionary.entries
                .filter { $0.review == .unreviewed }
                .sorted { $0.lastSeenAt > $1.lastSeenAt }
            let room = max(0, maxEntries - reviewed.count)
            dictionary.entries = reviewed + unreviewed.prefix(room)
        }

        try save(dictionary)
        return dictionary
    }

    /// 人によるチェック結果を書き戻す。該当が無ければ何もしない
    @discardableResult public func review(
        wrong: String,
        right: String,
        as review: CorrectionReview,
        now: Date
    ) throws -> CorrectionDictionary {
        var dictionary = load()
        guard let index = dictionary.entries.firstIndex(where: {
            $0.wrong == wrong && $0.right == right
        }) else { return dictionary }
        dictionary.entries[index].review = review
        dictionary.entries[index].reviewedAt = review == .unreviewed ? nil : now
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
