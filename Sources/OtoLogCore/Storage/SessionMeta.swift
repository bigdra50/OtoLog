import Foundation

// MARK: - SessionMeta

/// セッションディレクトリの meta.json の中身。
/// スキーマ拡張は schemaVersion を上げ、古い定義でも読めるよう未知キーは無視する。
public struct SessionMeta: Sendable, Equatable, Codable {
    // MARK: Lifecycle

    public init(
        schemaVersion: Int = 2,
        sessionID: UUID,
        title: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        endReason: String? = nil,
        endMessage: String? = nil,
        locale: String,
        source: AudioSourceKind,
        playbookID: String? = nil,
        pipeline: [String: PipelineTaskState]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.endMessage = endMessage
        self.locale = locale
        self.source = source
        self.playbookID = playbookID
        self.pipeline = pipeline
    }

    // MARK: Public

    /// 2 で終わり方（endReason / endMessage）を足した。足した項目は省略できるので、1 のファイルもそのまま読める
    public var schemaVersion: Int
    public var sessionID: UUID
    public var title: String?
    public var startedAt: Date
    public var endedAt: Date?
    /// 終わり方（"stopped" / "autoStopped" / "failed"）。記録中と、スキーマ1で書かれたファイルでは nil。
    /// 列挙型にしないのは、知らない値を書いた新しい版のファイルも読めるようにするため
    public var endReason: String?
    /// 失敗で終わったときの理由。ポップオーバーに出したのと同じ文言
    public var endMessage: String?
    public var locale: String
    public var source: AudioSourceKind
    /// 最後に実行したプレイブックとタスク状態（パイプライン未実行なら nil）
    public var playbookID: String?
    public var pipeline: [String: PipelineTaskState]?

    /// 閉じた時刻と終わり方を書き込む。理由の文言は失敗のときだけ残す
    public mutating func markEnded(at date: Date, reason: SessionEndReason) {
        endedAt = date
        switch reason {
        case .stopped:
            endReason = "stopped"
            endMessage = nil
        case .autoStopped:
            endReason = "autoStopped"
            endMessage = nil
        case let .failed(message):
            endReason = "failed"
            endMessage = message
        }
    }
}

// MARK: - SessionMetaCoder

/// meta.json の相互変換。人も読むため整形出力、diff とテストの安定のため決定的
/// （sortedKeys + ISO8601 ミリ秒。JSONLCoder と同じ時刻表現）。
public enum SessionMetaCoder {
    public static func encode(_ meta: SessionMeta) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            try container.encode(JSONLCoder.iso8601Millis(from: date))
        }
        return try encoder.encode(meta)
    }

    public static func decode(_ data: Data) throws -> SessionMeta {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = JSONLCoder.date(fromISO8601: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "invalid ISO8601 date: \(string)"
                )
            }
            return date
        }
        return try decoder.decode(SessionMeta.self, from: data)
    }
}
