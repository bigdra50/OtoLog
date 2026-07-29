import Foundation

// MARK: - SessionMeta

/// セッションディレクトリの meta.json の中身。
/// スキーマ拡張は schemaVersion を上げ、古い定義でも読めるよう未知キーは無視する。
public struct SessionMeta: Sendable, Equatable, Codable {
    // MARK: Lifecycle

    public init(
        schemaVersion: Int = 1,
        sessionID: UUID,
        title: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
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
        self.locale = locale
        self.source = source
        self.playbookID = playbookID
        self.pipeline = pipeline
    }

    // MARK: Public

    public var schemaVersion: Int
    public var sessionID: UUID
    public var title: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var locale: String
    public var source: AudioSourceKind
    /// 最後に実行したプレイブックとタスク状態（パイプライン未実行なら nil）
    public var playbookID: String?
    public var pipeline: [String: PipelineTaskState]?
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
