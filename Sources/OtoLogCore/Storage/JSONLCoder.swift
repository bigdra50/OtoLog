import Foundation

/// TranscriptSegment を JSONL の1行（改行なし）へ相互変換する。
/// 出力は sortedKeys + ISO8601(ミリ秒) で決定的にし、diff とテストを安定させる。
public enum JSONLCoder {
    // MARK: Public

    public static func encodeLine(_ segment: TranscriptSegment) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            try container.encode(iso8601Millis(from: date))
        }
        let data = try encoder.encode(segment)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decodeLine(_ line: String) throws -> TranscriptSegment {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = date(fromISO8601: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "invalid ISO8601 date: \(string)"
                )
            }
            return date
        }
        return try decoder.decode(TranscriptSegment.self, from: Data(line.utf8))
    }

    // MARK: Internal

    /// JSONEncoder/ISO8601DateFormatter は Sendable でないため共有せず毎回生成する。
    /// SessionMetaCoder と時刻表現を揃えるため internal に公開している
    static func iso8601Millis(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(fromISO8601 string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        // 秒精度のみの入力も受ける（他ツールで生成された jsonl の互換）
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
