import Foundation
@testable import OtoLogCore
import Testing

struct SessionClassifierTests {
    // MARK: Internal

    let jst = TimeZone(identifier: "Asia/Tokyo")!

    @Test func selectsPlaybookMatchingGeneratedID() async throws {
        try await withSession { root, ref in
            let classifier = SessionClassifier(
                saveDirectory: root, timeZone: jst, generator: FakeTextGenerator(result: "lecture")
            )
            let selected = try await classifier.classify(session: ref, candidates: BuiltInPlaybooks.all)
            #expect(selected?.id == "lecture")
        }
    }

    /// 出力の余計な空白・改行・引用は許容する
    @Test func toleratesDecoratedOutput() async throws {
        try await withSession { root, ref in
            let classifier = SessionClassifier(
                saveDirectory: root, timeZone: jst, generator: FakeTextGenerator(result: "  「meeting」\n")
            )
            let selected = try await classifier.classify(session: ref, candidates: BuiltInPlaybooks.all)
            #expect(selected?.id == "meeting")
        }
    }

    /// none や候補外の出力は「判定不能」として nil（勝手に実行しない）
    @Test func returnsNilForNoneOrUnknownAnswer() async throws {
        try await withSession { root, ref in
            let none = SessionClassifier(
                saveDirectory: root, timeZone: jst, generator: FakeTextGenerator(result: "none")
            )
            let noneResult = try await none.classify(session: ref, candidates: BuiltInPlaybooks.all)
            #expect(noneResult == nil)

            let unknown = SessionClassifier(
                saveDirectory: root, timeZone: jst, generator: FakeTextGenerator(result: "podcast")
            )
            let unknownResult = try await unknown.classify(session: ref, candidates: BuiltInPlaybooks.all)
            #expect(unknownResult == nil)
        }
    }

    /// プロンプトには候補の id・説明とログ抜粋が載る
    @Test func promptListsCandidatesWithDescriptionsAndLogSample() async throws {
        try await withSession { root, ref in
            let generator = FakeTextGenerator(result: "lecture")
            let classifier = SessionClassifier(saveDirectory: root, timeZone: jst, generator: generator)
            _ = try await classifier.classify(session: ref, candidates: BuiltInPlaybooks.all)

            let prompt = generator.receivedPrompts.first ?? ""
            #expect(prompt.contains("lecture"))
            #expect(prompt.contains("meeting"))
            #expect(prompt.contains(BuiltInPlaybooks.all[0].description))
            #expect(prompt.contains("ボクセル技術の講演です"))
        }
    }

    // MARK: Private

    private func withSession(_ body: (URL, SessionRef) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogTests-\(UUID().uuidString)", isDirectory: true)
        let name = "2026-07-29_1300"
        let sessionDir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let line = try JSONLCoder.encodeLine(TestFixtures.segment(text: "ボクセル技術の講演です"))
        try (line + "\n").write(
            to: sessionDir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8
        )
        let ref = SessionRef(
            directoryName: name, title: nil, startedAt: Date(timeIntervalSince1970: 1_785_297_600)
        )
        try await body(root, ref)
    }
}
