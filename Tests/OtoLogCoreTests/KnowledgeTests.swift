import Foundation
@testable import OtoLogCore
import Testing

/// 固有名詞に背景をつけて持つ前提知識。
/// 語を並べるだけでは「XREAL AURA」が何なのか分からず、音が近いだけの箇所まで
/// 引き寄せてしまう。何者かを添えて初めて、文脈の合う箇所だけ直せる。
struct KnowledgeTests {
    @Test func 見出しと本文をエントリにする() {
        let markdown = """
        # 前提知識

        ## XREAL AURA
        XREAL 社の AR グラス。Android XR を搭載する。

        ## トリラックス
        大塚製薬向けの案件名。
        """

        let entries = KnowledgeParser.entries(from: markdown)

        #expect(entries.count == 2)
        #expect(entries.first?.term == "XREAL AURA")
        #expect(entries.first?.body == "XREAL 社の AR グラス。Android XR を搭載する。")
        #expect(entries.last?.term == "トリラックス")
    }

    /// 本文が複数行でもまとめて1エントリにする
    @Test func 複数行の本文を保つ() {
        let markdown = """
        ## XREAL AURA
        XREAL 社の AR グラス。
        「エックスリアルオーラ」と認識されがち。
        """

        let entry = KnowledgeParser.entries(from: markdown).first

        #expect(entry?.body == "XREAL 社の AR グラス。\n「エックスリアルオーラ」と認識されがち。")
    }

    /// 見出しの括弧書きは用語の一部として残す（glossary.md がこの形で出る）
    @Test func 括弧つきの見出しをそのまま用語にする() {
        let entries = KnowledgeParser.entries(from: "## ライラ（Laila）\n社内製のレビュー支援ツール。")

        #expect(entries.first?.term == "ライラ（Laila）")
    }

    /// 本文の無い見出しは分類の見出しなので拾わない
    @Test func 本文のない見出しは捨てる() {
        let markdown = """
        ## AI・機械学習関連

        ## LLM
        大規模言語モデル。
        """

        #expect(KnowledgeParser.entries(from: markdown).map(\.term) == ["LLM"])
    }

    /// glossary.md の装飾（**文脈**：/ 参照: URL）はそのまま本文に含める。
    /// 生成物をそのまま貼れることを優先し、整形は求めない
    @Test func glossaryの体裁をそのまま受け入れる() {
        let markdown = """
        ## ボクセル（Voxel）
        **文脈**：レンダリングの単位として説明された。
        **定義**：3次元空間の格子点に置かれた体積要素。
        参照: https://example.com/voxel
        """

        let entry = KnowledgeParser.entries(from: markdown).first

        #expect(entry?.term == "ボクセル（Voxel）")
        #expect(entry?.body.contains("体積要素") == true)
    }

    @Test func 空なら何も返さない() {
        #expect(KnowledgeParser.entries(from: "").isEmpty)
        #expect(KnowledgeParser.entries(from: "# 見出しだけ").isEmpty)
    }

    /// `###` は本文の一部として残す。
    /// 「## 用語 / ### 定義」という書き方をしたときに、節を用語と取り違えないため
    @Test func 子見出しは本文として残す() {
        let markdown = """
        ## ボクセル

        ### 定義
        3次元の画素。
        """

        let entries = KnowledgeParser.entries(from: markdown)

        #expect(entries.map(\.term) == ["ボクセル"])
        #expect(entries.first?.body.contains("### 定義") == true)
    }

    @Test func ファイルから読み込める() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogKnowledge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("knowledge.md")
        try "## XREAL AURA\nAR グラス。\n".write(to: url, atomically: true, encoding: .utf8)

        #expect(KnowledgeStore(fileURL: url).load().map(\.term) == ["XREAL AURA"])
    }

    /// 未作成でも動く（置かなければ従来どおり）
    @Test func ファイルが無ければ空() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-\(UUID().uuidString).md")

        #expect(KnowledgeStore(fileURL: missing).load().isEmpty)
    }
}
