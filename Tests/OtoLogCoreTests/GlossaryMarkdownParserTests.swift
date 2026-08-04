import Foundation
@testable import OtoLogCore
import Testing

/// 構造化出力より前に生成された用語集を読む経路。
/// 体裁が定まらないので、分類で階層化された形も用語だけの形も受ける。
struct GlossaryMarkdownParserTests {
    /// 用語集が分類で階層化されていることがある。
    /// 「## AI・機械学習関連」は分類であって用語ではないので、その下の「### RAG」を拾う
    @Test func 子見出しがあるときは子を用語にする() {
        let markdown = """
        ## AI・機械学習関連

        ### RAG
        検索拡張生成。

        ### ハルシネーション
        誤った生成。

        ## ボクセル
        3次元の画素。
        """

        let entries = GlossaryMarkdownParser.entries(from: markdown)

        #expect(entries.map(\.term) == ["RAG", "ハルシネーション", "ボクセル"])
    }

    /// 分類の直下に説明が書かれていても、子見出しがあるなら子を優先する
    @Test func 分類に前置きがあっても子を用語にする() {
        let markdown = """
        ## グラフィックス関連
        この節では描画まわりの用語を挙げる。

        ### シェーダー
        GPU で動くプログラム。
        """

        #expect(GlossaryMarkdownParser.entries(from: markdown).map(\.term) == ["シェーダー"])
    }

    /// 子見出しの本文が空なら、その子は拾わない
    @Test func 本文のない子見出しは捨てる() {
        let markdown = """
        ## 分類

        ### 見出しだけ

        ### 中身あり
        説明。
        """

        #expect(GlossaryMarkdownParser.entries(from: markdown).map(\.term) == ["中身あり"])
    }
}
