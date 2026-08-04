import Foundation
@testable import OtoLogCore
import Testing

struct TranscriptReaderTests {
    // MARK: Internal

    let jst = TimeZone(identifier: "Asia/Tokyo")!

    @Test func availableSessionsListsSessionDirectoriesNewestFirst() throws {
        try withTempDir { dir in
            try makeSession(in: dir, name: "2026-07-28_0900", title: "古い会議", startedAt: 1_785_196_800)
            try makeSession(in: dir, name: "2026-07-29_1300", title: nil, startedAt: 1_785_297_600)
            // 無関係なファイル・旧日次形式・.bak は列挙しない
            try Data().write(to: dir.appendingPathComponent("2026-07-29.jsonl.bak"))
            try Data().write(to: dir.appendingPathComponent("notes.txt"))
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("無関係フォルダ"), withIntermediateDirectories: true
            )

            let sessions = TranscriptReader(directory: dir, timeZone: jst).availableSessions()

            #expect(sessions.map(\.directoryName) == ["2026-07-29_1300", "2026-07-28_0900"])
            #expect(sessions.map(\.title) == [nil, "古い会議"])
        }
    }

    /// meta.json が壊れていてもディレクトリ名（yyyy-MM-dd_HHmm）から復元して一覧に出す
    @Test func availableSessionsFallBackToDirectoryNameWhenMetaBroken() throws {
        try withTempDir { dir in
            let broken = dir.appendingPathComponent("2026-07-29_1300_壊れたセッション", isDirectory: true)
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
            try "{invalid json".write(to: broken.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)

            let sessions = TranscriptReader(directory: dir, timeZone: jst).availableSessions()

            #expect(sessions.count == 1)
            #expect(sessions.first?.directoryName == "2026-07-29_1300_壊れたセッション")
            #expect(sessions.first?.title == nil)
            // 開始時刻はディレクトリ名から復元（2026-07-29 13:00 JST）
            #expect(sessions.first?.startedAt == Date(timeIntervalSince1970: 1_785_297_600))
        }
    }

    /// 日付フォルダ階層（新構造）と旧フラット構造を同時に列挙できる
    @Test func listsNestedDateFolderAndLegacyFlatSessionsTogether() throws {
        try withTempDir { dir in
            try makeSession(in: dir, name: "2026-07-29/ボクセル講演", title: "ボクセル講演", startedAt: 1_785_297_600)
            try makeSession(in: dir, name: "2026-07-28_0900_旧形式", title: "旧形式", startedAt: 1_785_196_800)
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("briefs"), withIntermediateDirectories: true
            )

            let sessions = TranscriptReader(directory: dir, timeZone: jst).availableSessions()

            #expect(sessions.map(\.directoryName) == ["2026-07-29/ボクセル講演", "2026-07-28_0900_旧形式"])
            #expect(sessions.first?.displayName == "ボクセル講演")
        }
    }

    @Test func availableSessionsReturnsEmptyForMissingDirectory() {
        let reader = TranscriptReader(
            directory: URL(fileURLWithPath: "/nonexistent/otolog-\(UUID())"), timeZone: jst
        )
        #expect(reader.availableSessions().isEmpty)
    }

    /// クラッシュや録音中の追記競合で末尾に不完全な行があっても読めた分を返す
    @Test func segmentsSkipBrokenLines() throws {
        try withTempDir { dir in
            let ref = try makeSession(in: dir, name: "2026-07-29_1300", title: nil, startedAt: 1_785_297_600)
            let good = try JSONLCoder.encodeLine(TestFixtures.segment(text: "正常"))
            try (good + "\n{broken\n" + good + "\n").write(
                to: dir.appendingPathComponent("2026-07-29_1300/transcript.jsonl"),
                atomically: true, encoding: .utf8
            )

            let segments = try TranscriptReader(directory: dir, timeZone: jst).segments(in: ref)

            #expect(segments.map(\.text) == ["正常", "正常"])
        }
    }

    @Test func segmentsThrowsWhenTranscriptMissing() throws {
        try withTempDir { dir in
            let ref = try makeSession(in: dir, name: "2026-07-29_1300", title: nil, startedAt: 1_785_297_600)
            let reader = TranscriptReader(directory: dir, timeZone: jst)
            #expect(throws: TranscriptReaderError.self) {
                _ = try reader.segments(in: ref)
            }
        }
    }

    @Test func metaReadsSessionMetaAndReturnsNilWhenBroken() throws {
        try withTempDir { dir in
            let ref = try makeSession(in: dir, name: "2026-07-29_1300", title: "会議", startedAt: 1_785_297_600)
            let reader = TranscriptReader(directory: dir, timeZone: jst)
            #expect(reader.meta(in: ref)?.title == "会議")

            try "{broken".write(
                to: dir.appendingPathComponent("2026-07-29_1300/meta.json"), atomically: true, encoding: .utf8
            )
            #expect(reader.meta(in: ref) == nil)
        }
    }

    /// ビューワーの生成物一覧: <名前>.md のみで transcript.md は含めない
    @Test func generatedDocumentFileNamesExcludeTranscriptAndNonMarkdown() throws {
        try withTempDir { dir in
            let ref = try makeSession(in: dir, name: "2026-07-29_1300", title: nil, startedAt: 1_785_297_600)
            let sessionDir = dir.appendingPathComponent("2026-07-29_1300")
            for name in ["transcript.md", "transcript.jsonl", "summary.md", "correct.md", "meta.json", "notes.txt"] {
                try Data("x".utf8).write(to: sessionDir.appendingPathComponent(name))
            }
            // 作り直す前の版は退避してあるが、生成物の一覧には出さない
            let history = sessionDir.appendingPathComponent(
                GenerationHistory.directoryName, isDirectory: true
            )
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: history.appendingPathComponent("summary-20260729T040000Z.md"))

            let names = TranscriptReader(directory: dir, timeZone: jst).generatedDocumentFileNames(in: ref)
            #expect(names.sorted() == ["correct.md", "summary.md"])
        }
    }

    // MARK: Private

    @discardableResult private func makeSession(
        in dir: URL, name: String, title: String?, startedAt: TimeInterval
    ) throws -> SessionRef {
        let sessionDir = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let meta = SessionMeta(
            sessionID: UUID(),
            title: title,
            startedAt: Date(timeIntervalSince1970: startedAt),
            locale: "ja-JP",
            source: .system
        )
        try SessionMetaCoder.encode(meta).write(to: sessionDir.appendingPathComponent("meta.json"))
        return SessionRef(directoryName: name, title: title, startedAt: meta.startedAt)
    }

    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }
}
