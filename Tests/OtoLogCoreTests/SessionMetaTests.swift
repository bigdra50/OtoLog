import Foundation
@testable import OtoLogCore
import Testing

struct SessionMetaTests {
    let meta = SessionMeta(
        schemaVersion: 1,
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        title: "CEDEC講演",
        startedAt: Date(timeIntervalSince1970: 1_785_297_600),
        endedAt: Date(timeIntervalSince1970: 1_785_301_200.500),
        locale: "ja-JP",
        source: .system
    )

    /// meta.json は人も読むため整形出力、かつ diff 安定のため決定的（sortedKeys + ISO8601ms）
    @Test func encodesDeterministicPrettyJSON() throws {
        let data = try SessionMetaCoder.encode(meta)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == """
        {
          "endedAt" : "2026-07-29T05:00:00.500Z",
          "locale" : "ja-JP",
          "schemaVersion" : 1,
          "sessionID" : "00000000-0000-0000-0000-000000000001",
          "source" : "system",
          "startedAt" : "2026-07-29T04:00:00.000Z",
          "title" : "CEDEC講演"
        }
        """)
    }

    @Test func roundTripsThroughEncodeAndDecode() throws {
        let decoded = try SessionMetaCoder.decode(SessionMetaCoder.encode(meta))
        #expect(decoded == meta)
    }

    @Test func omitsNilTitleAndEndedAt() throws {
        var recording = meta
        recording.title = nil
        recording.endedAt = nil
        let text = try String(decoding: SessionMetaCoder.encode(recording), as: UTF8.self)
        #expect(!text.contains("title"))
        #expect(!text.contains("endedAt"))
        let decoded = try SessionMetaCoder.decode(SessionMetaCoder.encode(recording))
        #expect(decoded == recording)
    }

    /// 将来のスキーマ拡張で足されたキーを古い定義でも読める（前方互換）
    @Test func decodingIgnoresUnknownKeys() throws {
        let json = """
        {"schemaVersion":1,"sessionID":"00000000-0000-0000-0000-000000000001",
         "startedAt":"2026-07-29T04:00:00.000Z","locale":"ja-JP","source":"system",
         "futureField":{"nested":true}}
        """
        let decoded = try SessionMetaCoder.decode(Data(json.utf8))
        #expect(decoded.sessionID == meta.sessionID)
        #expect(decoded.title == nil)
    }
}
