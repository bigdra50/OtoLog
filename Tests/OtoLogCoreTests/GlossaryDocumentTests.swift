import Foundation
@testable import OtoLogCore
import Testing

/// 用語集は構造化出力で受け取る。
/// Markdown を書かせてパースすると、分類見出しを用語として拾うような取りこぼしが起きる。
struct GlossaryDocumentTests {
    @Test func JSONから読み込める() throws {
        let json = """
        {"terms":[
          {"term":"ボクセル","context":"描画単位として言及","definition":"3次元の画素。","reference":"https://example.com/voxel"},
          {"term":"チャンク","context":"メモリ管理の単位","definition":"分割した1区画。"}
        ]}
        """

        let document = try GlossaryDocument(json: json)

        #expect(document.terms.map(\.term) == ["ボクセル", "チャンク"])
        #expect(document.terms.first?.reference == "https://example.com/voxel")
        #expect(document.terms.last?.reference == nil)
    }

    /// 人が読む md は OtoLog が組み立てる。体裁が固定されるのでパースも確実になる
    @Test func 人が読むMarkdownを組み立てる() throws {
        let document = try GlossaryDocument(json: """
        {"terms":[{"term":"ボクセル","context":"描画単位として言及","definition":"3次元の画素。","reference":"https://example.com"}]}
        """)

        let markdown = GlossaryFormatter.markdown(from: document)

        #expect(markdown.contains("## ボクセル"))
        #expect(markdown.contains("### ログ内の文脈"))
        #expect(markdown.contains("描画単位として言及"))
        #expect(markdown.contains("### 定義"))
        #expect(markdown.contains("3次元の画素。"))
        #expect(markdown.contains("https://example.com"))
        // 強調は使わない。構造は見出しで表す
        #expect(!markdown.contains("**"))
    }

    @Test func 出典が無ければ出典欄を書かない() throws {
        let document = try GlossaryDocument(json: """
        {"terms":[{"term":"チャンク","context":"文脈","definition":"定義。"}]}
        """)

        #expect(!GlossaryFormatter.markdown(from: document).contains("出典"))
    }

    /// 組み立てた md は前提知識のパーサーがそのまま用語として読める
    @Test func 組み立てたMarkdownを前提知識として読める() throws {
        let document = try GlossaryDocument(json: """
        {"terms":[
          {"term":"ボクセル","context":"文脈A","definition":"定義A。"},
          {"term":"チャンク","context":"文脈B","definition":"定義B。"}
        ]}
        """)

        let entries = KnowledgeParser.entries(from: GlossaryFormatter.markdown(from: document))

        #expect(entries.map(\.term) == ["ボクセル", "チャンク"])
    }

    /// 前提知識へ渡すのは定義だけ。文脈まで入れるとプロンプトが無駄に膨らむ
    @Test func 前提知識の候補は定義を本文にする() throws {
        let document = try GlossaryDocument(json: """
        {"terms":[{"term":"ボクセル","context":"長い文脈の説明","definition":"3次元の画素。"}]}
        """)

        let entries = document.knowledgeEntries()

        #expect(entries.first?.body == "3次元の画素。")
    }

    @Test func 壊れたJSONはエラーになる() {
        #expect(throws: (any Error).self) { try GlossaryDocument(json: "{壊れている") }
    }

    /// モデルがコードフェンスで包んでしまっても読めるようにする
    @Test func コードフェンス付きでも読める() throws {
        let json = """
        ```json
        {"terms":[{"term":"ボクセル","context":"文脈","definition":"定義。"}]}
        ```
        """

        #expect(try GlossaryDocument(json: json).terms.count == 1)
    }
}
