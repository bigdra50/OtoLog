import Foundation
@testable import OtoLogCore
import Testing

struct PipelineTaskStateTests {
    @Test func roundTripsThroughSessionMeta() throws {
        var meta = try SessionMeta(
            sessionID: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            startedAt: Date(timeIntervalSince1970: 1_785_297_600),
            locale: "ja-JP",
            source: .system
        )
        meta.playbookID = "lecture"
        meta.pipeline = [
            "correct": PipelineTaskState(
                status: .done,
                outputFile: "correct.md",
                startedAt: Date(timeIntervalSince1970: 1_785_297_600),
                finishedAt: Date(timeIntervalSince1970: 1_785_297_660)
            ),
            "summary": PipelineTaskState(status: .failed, error: "claude が失敗しました"),
        ]

        let decoded = try SessionMetaCoder.decode(SessionMetaCoder.encode(meta))

        #expect(decoded == meta)
        #expect(decoded.pipeline?["correct"]?.status == .done)
        #expect(decoded.pipeline?["summary"]?.error == "claude が失敗しました")
    }

    /// Phase A 時点の meta（pipeline フィールドなし）も読める後方互換
    @Test func decodesLegacyMetaWithoutPipelineFields() throws {
        let legacy = """
        {"locale":"ja-JP","schemaVersion":1,"sessionID":"00000000-0000-0000-0000-000000000001",
         "source":"system","startedAt":"2026-07-29T04:00:00.000Z"}
        """
        let decoded = try SessionMetaCoder.decode(Data(legacy.utf8))
        #expect(decoded.playbookID == nil)
        #expect(decoded.pipeline == nil)
    }
}
