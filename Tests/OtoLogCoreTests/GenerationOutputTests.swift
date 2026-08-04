import Foundation
@testable import OtoLogCore
import Testing

/// 構造化出力の生成結果を、保存する形へ振り分ける。
/// JSON が機械用の正本で、md はそこから組み立てた人が読む派生物。
struct GenerationOutputTests {
    let json = #"{"terms":[{"term":"ボクセル","context":"文脈","definition":"3次元の画素。"}]}"#

    @Test func 用語集はJSONを残しMarkdownを組み立てる() {
        let output = GenerationOutput.files(templateID: "glossary", generated: json)

        #expect(output.json == json)
        #expect(output.markdown.contains("## ボクセル"))
        #expect(output.markdown.contains("3次元の画素。"))
    }

    /// スキーマの無いテンプレートは今までどおり本文をそのまま保存する
    @Test func 他のテンプレートはそのまま保存する() {
        let output = GenerationOutput.files(templateID: "minutes", generated: "# 議事録\n本文")

        #expect(output.json == nil)
        #expect(output.markdown == "# 議事録\n本文")
    }

    /// スキーマを指示しても JSON にならないことがある。
    /// そのときは本文をそのまま残す（生成結果を捨てるほうが害が大きい）
    @Test func 用語集がJSONでなければそのまま残す() {
        let output = GenerationOutput.files(templateID: "glossary", generated: "## ボクセル\n説明")

        #expect(output.json == nil)
        #expect(output.markdown == "## ボクセル\n説明")
    }
}
