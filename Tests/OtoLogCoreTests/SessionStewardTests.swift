import Foundation
@testable import OtoLogCore
import Testing

struct SessionStewardTests {
    // MARK: Internal

    let jst = TimeZone(identifier: "Asia/Tokyo")!
    /// 2026-07-29 14:00 JST（各セッションの後）を「現在」とする
    let now = Date(timeIntervalSince1970: 1_785_301_200)

    @Test func findsCompletedSessionsMissingTitleOrPipeline() throws {
        try withTempDir { root in
            try makeSession(in: root, name: "2026-07-29_0900", title: nil, playbookID: nil, ended: true)
            try makeSession(in: root, name: "2026-07-29_1000", title: "済み", playbookID: nil, ended: true)
            try makeSession(in: root, name: "2026-07-29_1100", title: "完了", playbookID: "lecture", ended: true)

            let findings = SessionSteward(saveDirectory: root, timeZone: jst)
                .findings(now: now)

            #expect(findings.count == 2)
            #expect(findings[0].session.directoryName == "2026-07-29_1000")
            #expect(findings[0].needsTitle == false)
            #expect(findings[0].needsPipeline == true)
            #expect(findings[1].session.directoryName == "2026-07-29_0900")
            #expect(findings[1].needsTitle == true)
        }
    }

    /// 記録中（endedAt なしで新しい）セッションは対象外。ただし古い残骸（クラッシュ）は拾う
    @Test func skipsRecentUnfinishedButFindsStaleOnes() throws {
        try withTempDir { root in
            // 1時間前開始・未終了 = 記録中の可能性 → 対象外
            try makeSession(in: root, name: "2026-07-29_1300", title: nil, playbookID: nil, ended: false)
            // 2日前開始・未終了 = クラッシュ残骸 → 対象
            try makeSession(in: root, name: "2026-07-27_0900", title: nil, playbookID: nil, ended: false)

            let findings = SessionSteward(saveDirectory: root, timeZone: jst)
                .findings(now: now)

            #expect(findings.map(\.session.directoryName) == ["2026-07-27_0900"])
        }
    }

    // MARK: Private

    private func makeSession(
        in root: URL, name: String, title: String?, playbookID: String?, ended: Bool
    ) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let namer = SessionDirectoryNamer(timeZone: jst)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = jst
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let startedAt = formatter.date(from: String(name.prefix(15)))!
        _ = namer
        var meta = SessionMeta(
            sessionID: UUID(), title: title, startedAt: startedAt,
            locale: "ja-JP", source: .system, playbookID: playbookID
        )
        if ended {
            meta.endedAt = startedAt.addingTimeInterval(1800)
        }
        try SessionMetaCoder.encode(meta).write(to: dir.appendingPathComponent("meta.json"))
        let line = try JSONLCoder.encodeLine(TestFixtures.segment(text: "本文", finalizedAt: startedAt))
        try (line + "\n").write(
            to: dir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8
        )
    }

    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }
}
