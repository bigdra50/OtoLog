import Foundation
@testable import OtoLogCore
import Testing

struct DailyMigrationToolTests {
    // MARK: Internal

    let jst = TimeZone(identifier: "Asia/Tokyo")!

    @Test func migratesDailyFileIntoSessionDirectory() throws {
        try withTempDir { dir in
            let segment = TestFixtures.segment(text: "こんにちは")
            try writeDaily(lines: [JSONLCoder.encodeLine(segment)], to: dir)
            try "# 2026-07-29\n\n- **13:00:00** こんにちは\n".write(
                to: dir.appendingPathComponent("2026-07-29.md"), atomically: true, encoding: .utf8
            )

            let migrated = try DailyMigrationTool(timeZone: jst).migrate(directory: dir)

            #expect(migrated.map(\.directoryName) == ["2026-07-29/1300"])
            let sessionDir = dir.appendingPathComponent("2026-07-29/1300")
            // 正本 jsonl は原文行のまま引き継がれる
            let jsonl = try String(contentsOf: sessionDir.appendingPathComponent("transcript.jsonl"), encoding: .utf8)
            #expect(try jsonl == (JSONLCoder.encodeLine(segment)) + "\n")
            // md はセッション見出しで再生成される
            let md = try String(contentsOf: sessionDir.appendingPathComponent("transcript.md"), encoding: .utf8)
            #expect(md == "# 2026-07-29 13:00\n\n- **13:00:00** こんにちは\n")
            let meta = try SessionMetaCoder.decode(Data(contentsOf: sessionDir.appendingPathComponent("meta.json")))
            #expect(meta.sessionID == segment.sessionID)
            #expect(meta.endedAt == segment.finalizedAt)
            // 旧ファイルは .bak へ退避
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("2026-07-29.jsonl.bak").path))
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("2026-07-29.md.bak").path))
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("2026-07-29.jsonl").path))
        }
    }

    /// 1日のファイルに複数セッションが混ざっていても sessionID で分割する
    @Test func splitsMultipleSessionsInOneDailyFile() throws {
        try withTempDir { dir in
            var first = TestFixtures.segment(text: "朝のセッション")
            first.sessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
            first.sessionStartedAt = Date(timeIntervalSince1970: 1_785_283_200) // 09:00 JST
            var second = TestFixtures.segment(text: "昼のセッション")
            second.sessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
            second.sessionStartedAt = Date(timeIntervalSince1970: 1_785_297_600) // 13:00 JST
            try writeDaily(
                lines: [JSONLCoder.encodeLine(first), JSONLCoder.encodeLine(second)], to: dir
            )

            let migrated = try DailyMigrationTool(timeZone: jst).migrate(directory: dir)

            #expect(migrated.map(\.directoryName).sorted() == ["2026-07-29/0900", "2026-07-29/1300"])
        }
    }

    /// 再実行しても .bak は対象外なので二重変換しない
    @Test func isIdempotentAcrossReruns() throws {
        try withTempDir { dir in
            try writeDaily(lines: [JSONLCoder.encodeLine(TestFixtures.segment(text: "一度だけ"))], to: dir)
            let tool = DailyMigrationTool(timeZone: jst)

            let firstRun = try tool.migrate(directory: dir)
            let secondRun = try tool.migrate(directory: dir)

            #expect(firstRun.count == 1)
            #expect(secondRun.isEmpty)
        }
    }

    @Test func skipsBrokenLinesAndGeneratedArtifacts() throws {
        try withTempDir { dir in
            let good = try JSONLCoder.encodeLine(TestFixtures.segment(text: "正常"))
            try writeDaily(lines: [good, "{broken"], to: dir)
            // 旧構造の生成物はそのまま残す
            try "校正結果".write(
                to: dir.appendingPathComponent("2026-07-29.correct.md"), atomically: true, encoding: .utf8
            )

            let migrated = try DailyMigrationTool(timeZone: jst).migrate(directory: dir)

            #expect(migrated.count == 1)
            let jsonl = try String(
                contentsOf: dir.appendingPathComponent("2026-07-29/1300/transcript.jsonl"), encoding: .utf8
            )
            #expect(jsonl == good + "\n")
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("2026-07-29.correct.md").path))
        }
    }

    // MARK: Private

    private func writeDaily(lines: [String], to dir: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("2026-07-29.jsonl"), atomically: true, encoding: .utf8
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
