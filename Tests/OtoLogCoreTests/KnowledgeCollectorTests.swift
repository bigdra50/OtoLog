import Foundation
@testable import OtoLogCore
import Testing

/// 生成済みの glossary.md から前提知識候補を集める。
/// 用語集は既に「用語＋文脈＋定義」の形で出ているので、そのまま候補になる。
struct KnowledgeCollectorTests {
    // MARK: Internal

    let now = Date(timeIntervalSince1970: 1_785_297_600)

    @Test func 用語集から候補を作る() throws {
        try withSessions { root in
            try writeGlossary(in: root, session: "2026-07-31/会議", body: """
            ## ボクセル
            3次元の画素。

            ## トリらっくす
            アプリの名前。
            """)

            let suggestions = KnowledgeCollector.collect(
                directory: root, knowledge: [], dismissed: [], now: now
            )

            #expect(suggestions.map(\.term) == ["ボクセル", "トリらっくす"])
            #expect(suggestions.first?.origin == "2026-07-31/会議")
        }
    }

    /// 確定済みの用語は候補に出さない
    @Test func 確定済みは除く() throws {
        try withSessions { root in
            try writeGlossary(in: root, session: "2026-07-31/会議", body: "## ボクセル\n3次元の画素。")

            let suggestions = KnowledgeCollector.collect(
                directory: root,
                knowledge: [KnowledgeEntry(term: "ボクセル", body: "既に書いた説明")],
                dismissed: [], now: now
            )

            #expect(suggestions.isEmpty)
        }
    }

    /// 却下済みも出さない。出すと何度でも同じものを突き返すことになる
    @Test func 却下済みは除く() throws {
        try withSessions { root in
            try writeGlossary(in: root, session: "2026-07-31/会議", body: "## ハルシネーション\n誤った生成。")

            let suggestions = KnowledgeCollector.collect(
                directory: root, knowledge: [], dismissed: ["ハルシネーション"], now: now
            )

            #expect(suggestions.isEmpty)
        }
    }

    /// 同じ用語が複数セッションに出たら1件にまとめる
    @Test func 重複する用語は最初の1件にまとめる() throws {
        try withSessions { root in
            try writeGlossary(in: root, session: "2026-07-30/A", body: "## ボクセル\n説明A。")
            try writeGlossary(in: root, session: "2026-07-31/B", body: "## ボクセル\n説明B。")

            let suggestions = KnowledgeCollector.collect(
                directory: root, knowledge: [], dismissed: [], now: now
            )

            #expect(suggestions.count == 1)
        }
    }

    @Test func 用語集が無ければ候補も無い() throws {
        try withSessions { root in
            #expect(KnowledgeCollector.collect(directory: root, knowledge: [], dismissed: [], now: now).isEmpty)
        }
    }

    /// 保存先のパス途中にシンボリックリンクがあっても由来はセッション相対で出す。
    /// 走査で返る URL は実体パスに解決される一方、設定値の保存先は未解決のままなので、
    /// 素朴に前方一致を取ると `/Volumes/.../logs/...` という絶対パスが出てしまう
    @Test func シンボリックリンク越しでも由来を相対で示す() throws {
        try withSessions { root in
            let real = root.appendingPathComponent("real/logs")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try writeGlossary(in: real, session: "2026-07-31/会議", body: "## ボクセル\n3次元の画素。")
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(
                at: link, withDestinationURL: root.appendingPathComponent("real")
            )

            let suggestions = KnowledgeCollector.collect(
                directory: link.appendingPathComponent("logs"),
                knowledge: [], dismissed: [], now: now
            )

            #expect(suggestions.first?.origin == "2026-07-31/会議")
        }
    }

    /// 生成物の体裁（**ラベル**）は持ち込まない。
    /// 編集欄には生テキストが出るので記号がそのまま見えるうえ、プロンプトも無駄に長くなる
    @Test func 強調記号を落として取り込む() throws {
        try withSessions { root in
            try writeGlossary(in: root, session: "2026-07-31/会議", body: """
            ## ボクセル
            **ログ内の文脈**
            3次元の画素として説明された。

            **定義**
            体積要素のこと。
            """)

            let suggestions = KnowledgeCollector.collect(
                directory: root, knowledge: [], dismissed: [], now: now
            )

            let body = try #require(suggestions.first?.body)
            #expect(!body.contains("**"))
            #expect(body.contains("ログ内の文脈"))
            #expect(body.contains("体積要素のこと。"))
        }
    }

    /// 構造化出力があればそちらを使う。Markdown のパースに頼らないのが本筋
    @Test func 用語集のJSONがあれば優先する() throws {
        try withSessions { root in
            let dir = root.appendingPathComponent("2026-07-31/会議")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try #"{"terms":[{"term":"ボクセル","context":"文脈","definition":"3次元の画素。"}]}"#
                .write(to: dir.appendingPathComponent("glossary.json"), atomically: true, encoding: .utf8)
            // md 側には分類見出しの古い体裁を置いておき、JSON が優先されることを見る
            try writeGlossary(in: root, session: "2026-07-31/会議", body: "## 分類\n### 別の用語\n説明。")

            let suggestions = KnowledgeCollector.collect(
                directory: root, knowledge: [], dismissed: [], now: now
            )

            #expect(suggestions.map(\.term) == ["ボクセル"])
            #expect(suggestions.first?.body == "3次元の画素。")
        }
    }

    // MARK: Private

    private func writeGlossary(in root: URL, session: String, body: String) throws {
        let dir = root.appendingPathComponent(session)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 生成物には由来コメントが付く。候補集めがそれに引きずられないことも見る
        let contents = "<!-- otolog:generated template=glossary -->\n\n" + body + "\n"
        try contents.write(to: dir.appendingPathComponent("glossary.md"), atomically: true, encoding: .utf8)
    }

    private func withSessions(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogKC-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }
}
