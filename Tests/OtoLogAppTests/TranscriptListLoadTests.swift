import Foundation
@testable import OtoLogApp
import OtoLogCore
import Testing

/// TranscriptListView の読み込み（原文の正規化・補正の突合・差分抽出）を検証する。
struct TranscriptListLoadTests {
    @Test func 補正なしは原文のみを正規化して返す() throws {
        try SessionFixture.withTempDir { root in
            let ref = try SessionFixture.make(
                in: root, name: "2026-07-29/1300", texts: ["こんにちは  \n世界", "二行目"]
            )
            let content = TranscriptListView.load(
                directory: root, session: ref, timeZone: SessionFixture.jst
            )
            #expect(content.originalLines.map(\.text) == ["こんにちは 世界", "二行目"])
            #expect(content.originalLines.map(\.time) == ["13:00:00", "13:00:05"])
            #expect(content.correctedLines == nil)
            #expect(content.diffEntries.isEmpty)
        }
    }

    @Test func 補正ありは補正行と変更行だけの差分を返す() throws {
        try SessionFixture.withTempDir { root in
            let correct = """
            <!-- otolog:generated template=correct source=transcript.jsonl -->
            [13:00:00] こんにちは世界
            [13:00:05] 二行目
            """
            let ref = try SessionFixture.make(
                in: root, name: "2026-07-29/1300", texts: ["こんにちわ世界", "二行目"],
                documents: ["correct.md": correct]
            )
            let content = TranscriptListView.load(
                directory: root, session: ref, timeZone: SessionFixture.jst
            )
            #expect(content.correctedLines?.map(\.text) == ["こんにちは世界", "二行目"])
            // 変更のない「二行目」は差分に含まれない
            #expect(content.diffEntries.map(\.time) == ["13:00:00"])
        }
    }

    @Test func セッション不在でも空の結果を返す() throws {
        try SessionFixture.withTempDir { root in
            let ref = SessionRef(directoryName: "2026-07-29/1300", title: nil, startedAt: Date())
            let content = TranscriptListView.load(
                directory: root, session: ref, timeZone: SessionFixture.jst
            )
            #expect(content.originalLines.isEmpty)
            #expect(content.correctedLines == nil)
        }
    }
}
