import Foundation
@testable import OtoLogCore
import Testing

/// 前提知識は AI が候補を出し、人が編集して確定させる。
/// 推測で書いた説明は外れる（「トリらっくす」を案件名と読み違えた例がある）ので、
/// 確定は必ず人の手を通す。
struct KnowledgeSuggestionTests {
    // MARK: Internal

    let now = Date(timeIntervalSince1970: 1_785_297_600)

    @Test func 提案を保存して読み直せる() throws {
        try withTempDir { dir in
            let store = KnowledgeSuggestionStore(fileURL: dir.appendingPathComponent("s.json"))

            try store.save([suggestion(term: "トリらっくす")])

            #expect(store.load().map(\.term) == ["トリらっくす"])
        }
    }

    /// 承認すると knowledge.md へ追記され、提案からは消える
    @Test func 承認すると前提知識へ移る() throws {
        try withTempDir { dir in
            let knowledgeURL = dir.appendingPathComponent("knowledge.md")
            let store = KnowledgeSuggestionStore(fileURL: dir.appendingPathComponent("s.json"))
            try store.save([suggestion(term: "トリらっくす", body: "自社のデジタルペットアプリ。")])

            try store.accept(
                KnowledgeEntry(term: "トリらっくす", body: "自社のデジタルペットアプリ。"),
                into: KnowledgeStore(fileURL: knowledgeURL)
            )

            #expect(store.load().isEmpty)
            #expect(KnowledgeStore(fileURL: knowledgeURL).load().map(\.term) == ["トリらっくす"])
        }
    }

    /// 人が説明を書き直してから確定できる（提案の本文をそのまま採らない）
    @Test func 編集した内容で確定できる() throws {
        try withTempDir { dir in
            let knowledgeURL = dir.appendingPathComponent("knowledge.md")
            let store = KnowledgeSuggestionStore(fileURL: dir.appendingPathComponent("s.json"))
            try store.save([suggestion(term: "トリらっくす", body: "大塚製薬向けの案件名。")])

            try store.accept(
                KnowledgeEntry(term: "トリらっくす", body: "アップフロンティアの自社アプリ。"),
                into: KnowledgeStore(fileURL: knowledgeURL)
            )

            let saved = KnowledgeStore(fileURL: knowledgeURL).load()
            #expect(saved.first?.body == "アップフロンティアの自社アプリ。")
        }
    }

    /// 既存の前提知識を消さずに追記する
    @Test func 既存の前提知識へ追記する() throws {
        try withTempDir { dir in
            let knowledgeURL = dir.appendingPathComponent("knowledge.md")
            try "## XREAL AURA\nXR グラス。\n".write(to: knowledgeURL, atomically: true, encoding: .utf8)
            let store = KnowledgeSuggestionStore(fileURL: dir.appendingPathComponent("s.json"))
            try store.save([suggestion(term: "トリらっくす")])

            try store.accept(
                KnowledgeEntry(term: "トリらっくす", body: "自社アプリ。"),
                into: KnowledgeStore(fileURL: knowledgeURL)
            )

            #expect(KnowledgeStore(fileURL: knowledgeURL).load().map(\.term) == ["XREAL AURA", "トリらっくす"])
        }
    }

    /// 却下したものは記録に残す。残さないと次の走査で何度でも出てくる
    @Test func 却下は記録され再提案されない() throws {
        try withTempDir { dir in
            let store = KnowledgeSuggestionStore(fileURL: dir.appendingPathComponent("s.json"))
            try store.save([suggestion(term: "ハルシネーション")])

            try store.dismiss(term: "ハルシネーション")

            #expect(store.load().filter { $0.state == .pending }.isEmpty)
            #expect(store.isDismissed("ハルシネーション"))
        }
    }

    @Test func 未作成なら空() throws {
        try withTempDir { dir in
            #expect(KnowledgeSuggestionStore(fileURL: dir.appendingPathComponent("none.json")).load().isEmpty)
        }
    }

    // MARK: Private

    private func suggestion(term: String, body: String = "説明の下書き。") -> KnowledgeSuggestion {
        KnowledgeSuggestion(term: term, body: body, origin: "2026-07-31/会議", createdAt: now)
    }

    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogKS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }
}
