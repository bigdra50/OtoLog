import Foundation
@testable import OtoLogCore
import Testing

struct PostProcessRunnerTests {
    // MARK: Internal

    let jst = TimeZone(identifier: "Asia/Tokyo")!
    let template = GenerationTemplate(id: "minutes", displayName: "議事録", instructions: "整理する", isBuiltIn: true)
    let session = SessionRef(
        directoryName: "2026-07-29_1300",
        title: nil,
        startedAt: Date(timeIntervalSince1970: 1_785_297_600)
    )

    @Test func writesGeneratedMarkdownIntoSessionDirectory() async throws {
        try await withTempDir { dir in
            try writeTranscript(["こんにちは"], to: dir)
            let generator = FakeTextGenerator(result: "# 議事録\n\n- 決定: A")
            let runner = makeRunner(directory: dir, generator: generator)

            let url = try await runner.run(session: session, template: template)

            #expect(url.path.hasSuffix("2026-07-29_1300/minutes.md"))
            let contents = try String(contentsOf: url, encoding: .utf8)
            #expect(contents.hasPrefix(
                "<!-- otolog:generated template=minutes source=transcript.jsonl generatedAt=2026-07-29T04:00:00Z -->\n\n"
            ))
            #expect(contents.contains("- 決定: A"))
            // プロンプトにはタイムスタンプ付きログが載る（JST 変換の確認）
            #expect(generator.receivedPrompts.first?.contains("[13:00:00] こんにちは") == true)
        }
    }

    /// 生成物は再生成可能な派生物。再実行は前回の出力を残さず置き換える
    @Test func rerunOverwritesPreviousOutput() async throws {
        try await withTempDir { dir in
            try writeTranscript(["こんにちは"], to: dir)
            let generator = FakeTextGenerator(result: "1回目")
            let runner = makeRunner(directory: dir, generator: generator)

            _ = try await runner.run(session: session, template: template)
            generator.result = "2回目"
            let url = try await runner.run(session: session, template: template)

            let contents = try String(contentsOf: url, encoding: .utf8)
            #expect(contents.contains("2回目"))
            #expect(!contents.contains("1回目"))
        }
    }

    /// モデルが指示に反して全体をコードフェンスで包んだ場合に備える安価な堅牢化
    @Test func stripsWrappingCodeFence() async throws {
        try await withTempDir { dir in
            try writeTranscript(["こんにちは"], to: dir)
            let generator = FakeTextGenerator(result: "```markdown\n# 本文\n```")
            let runner = makeRunner(directory: dir, generator: generator)

            let url = try await runner.run(session: session, template: template)

            let contents = try String(contentsOf: url, encoding: .utf8)
            #expect(contents.contains("# 本文"))
            #expect(!contents.contains("```"))
        }
    }

    @Test func throwsForEmptyTranscript() async throws {
        try await withTempDir { dir in
            try writeTranscript([], to: dir)
            let runner = makeRunner(directory: dir, generator: FakeTextGenerator())
            await #expect(throws: PostProcessError.self) {
                _ = try await runner.run(session: self.session, template: self.template)
            }
        }
    }

    /// 分割生成は未対応のため、上限超過は claude を呼ぶ前に即時・無課金で失敗させる
    @Test func throwsBeforeGeneratingWhenPromptTooLarge() async throws {
        try await withTempDir { dir in
            try writeTranscript([String(repeating: "あ", count: 500)], to: dir)
            let generator = FakeTextGenerator(result: "使われない")
            let runner = PostProcessRunner(
                directory: dir, timeZone: jst, generator: generator,
                maxPromptCharacters: 100, now: { Date(timeIntervalSince1970: 1_785_297_600) }
            )
            await #expect(throws: PostProcessError.self) {
                _ = try await runner.run(session: self.session, template: self.template)
            }
            #expect(generator.receivedPrompts.isEmpty)
        }
    }

    // MARK: Private

    private func makeRunner(directory: URL, generator: FakeTextGenerator) -> PostProcessRunner {
        PostProcessRunner(
            directory: directory, timeZone: jst, generator: generator,
            correctionStore: nil, // テストから実 config を汚さない
            now: { Date(timeIntervalSince1970: 1_785_297_600) }
        )
    }

    private func writeTranscript(_ texts: [String], to dir: URL) throws {
        let sessionDir = dir.appendingPathComponent(session.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let lines = try texts.map { try JSONLCoder.encodeLine(TestFixtures.segment(text: $0)) }
        let contents = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try contents.write(
            to: sessionDir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8
        )
    }

    private func withTempDir(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }
}
