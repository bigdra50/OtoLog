import Foundation
@testable import OtoLogCore
import Testing

struct StructureMigrationToolTests {
    // MARK: Internal

    let jst = TimeZone(identifier: "Asia/Tokyo")!

    /// タイトル持ちはタイトル名で、タイトルなしは時刻名で日付フォルダへ移る
    @Test func movesFlatSessionsIntoDateFolders() throws {
        try withTempDir { root in
            try makeFlatSession(in: root, name: "2026-07-29_1300_講演", title: "講演")
            try makeFlatSession(
                in: root, name: "2026-07-29_2100", title: nil,
                startedAt: 1_785_326_400 // 21:00 JST
            )
            // 新構造のセッションと無関係ディレクトリは触らない
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("2026-07-28/既存"), withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("briefs"), withIntermediateDirectories: true
            )

            let migrated = try StructureMigrationTool(timeZone: jst).migrate(directory: root)

            #expect(migrated.map(\.directoryName).sorted() == ["2026-07-29/2100", "2026-07-29/講演"])
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-07-29/講演/meta.json").path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-07-29_1300_講演").path))
            // 再実行は対象なし（冪等）
            #expect(try StructureMigrationTool(timeZone: jst).migrate(directory: root).isEmpty)
        }
    }

    /// 同名タイトルが既にあれば連番で衝突を避ける
    @Test func resolvesTitleCollisionWithSuffix() throws {
        try withTempDir { root in
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("2026-07-29/講演"), withIntermediateDirectories: true
            )
            try makeFlatSession(in: root, name: "2026-07-29_1300_講演", title: "講演")

            let migrated = try StructureMigrationTool(timeZone: jst).migrate(directory: root)

            #expect(migrated.map(\.directoryName) == ["2026-07-29/講演-2"])
        }
    }

    // MARK: Private

    private func makeFlatSession(
        in root: URL, name: String, title: String?, startedAt: TimeInterval = 1_785_297_600
    ) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = SessionMeta(
            sessionID: UUID(), title: title,
            startedAt: Date(timeIntervalSince1970: startedAt),
            locale: "ja-JP", source: .system
        )
        try SessionMetaCoder.encode(meta).write(to: dir.appendingPathComponent("meta.json"))
        try "x".write(to: dir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)
    }

    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }
}
