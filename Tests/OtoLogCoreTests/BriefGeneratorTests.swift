import Foundation
@testable import OtoLogCore
import Testing

struct BriefGeneratorTests {
    // MARK: Internal

    let jst = TimeZone(identifier: "Asia/Tokyo")!

    /// 過去セッションの要約（あれば summary、なければ transcript 冒頭）を材料にする
    @Test func collectsSummariesOrTranscriptHeadsFromRecentSessions() async throws {
        try await withTempDir { root in
            try makeSession(
                in: root, name: "2026-07-28_0900", title: "前回講演",
                startedAt: 1_785_196_800, transcript: "前回のログ本文",
                summary: "前回の要約テキストXYZ"
            )
            try makeSession(
                in: root, name: "2026-07-29_1300", title: nil,
                startedAt: 1_785_297_600, transcript: "要約なしセッションの冒頭ABC"
            )
            let generator = FakeTextGenerator(result: "# ブリーフ\n\n前回までの要点")
            let brief = BriefGenerator(
                saveDirectory: root, timeZone: jst, generator: generator,
                now: { Date(timeIntervalSince1970: 1_785_301_200) }
            )

            let url = try await brief.generate(topic: "ボクセル技術の続き")

            let prompt = generator.receivedPrompts.first ?? ""
            #expect(prompt.contains("ボクセル技術の続き"))
            #expect(prompt.contains("前回の要約テキストXYZ"))
            #expect(prompt.contains("要約なしセッションの冒頭ABC"))
            #expect(prompt.contains("前回講演"))

            #expect(url.path.contains("/briefs/"))
            let contents = try String(contentsOf: url, encoding: .utf8)
            #expect(contents.hasPrefix("<!-- otolog:generated template=brief"))
            #expect(contents.contains("前回までの要点"))
        }
    }

    @Test func throwsWhenNoPastSessions() async throws {
        try await withTempDir { root in
            let brief = BriefGenerator(
                saveDirectory: root, timeZone: jst, generator: FakeTextGenerator(result: "使われない")
            )
            await #expect(throws: BriefGeneratorError.self) {
                _ = try await brief.generate(topic: nil)
            }
        }
    }

    // MARK: Private

    private func makeSession(
        in root: URL, name: String, title: String?, startedAt: TimeInterval,
        transcript: String, summary: String? = nil
    ) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = SessionMeta(
            sessionID: UUID(), title: title,
            startedAt: Date(timeIntervalSince1970: startedAt),
            locale: "ja-JP", source: .system
        )
        try SessionMetaCoder.encode(meta).write(to: dir.appendingPathComponent("meta.json"))
        let line = try JSONLCoder.encodeLine(
            TestFixtures.segment(text: transcript, finalizedAt: Date(timeIntervalSince1970: startedAt))
        )
        try (line + "\n").write(
            to: dir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8
        )
        if let summary {
            try "<!-- otolog:generated template=summary source=transcript.jsonl generatedAt=x -->\n\n\(summary)\n"
                .write(to: dir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        }
    }

    private func withTempDir(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }
}
