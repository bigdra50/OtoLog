import Foundation
@testable import OtoLogCore
import Testing

/// アクションアイテムは構造化出力で受け取る。
/// 完了したかを機械が追う必要があるので、型を固定する
/// （ニュアンスを含む現況メモとは器を分ける）。
struct ActionDocumentTests {
    @Test func JSONから読み込める() throws {
        let json = """
        {"actions":[
          {"task":"見積もりを完了する","owner":"鬼村","due":"2026-07-31","at":"11:04:25","decided":true},
          {"task":"絵コンテを3本仕上げる"}
        ]}
        """

        let document = try ActionDocument(json: json)

        #expect(document.actions.map(\.task) == ["見積もりを完了する", "絵コンテを3本仕上げる"])
        #expect(document.actions.first?.owner == "鬼村")
        #expect(document.actions.first?.decided == true)
        // 担当も期限も言及が無ければ空のまま。埋めさせない
        #expect(document.actions.last?.owner == nil)
        #expect(document.actions.last?.due == nil)
    }

    /// 決定に基づくものと提案止まりを分けて出す
    @Test func 決定と提案を見出しで分けて組み立てる() throws {
        let document = try ActionDocument(json: """
        {"actions":[
          {"task":"見積もりを完了する","owner":"鬼村","decided":true},
          {"task":"ビーコンでの代替を検討する","decided":false}
        ]}
        """)

        let markdown = ActionFormatter.markdown(from: document)

        #expect(markdown.contains("## 決定事項"))
        #expect(markdown.contains("## 提案・検討中"))
        #expect(markdown.contains("- [ ] 見積もりを完了する"))
        #expect(markdown.contains("鬼村"))
        #expect(!markdown.contains("**"))
    }

    /// 片方しか無ければ、その見出しだけを書く
    @Test func 該当が無い見出しは書かない() throws {
        let document = try ActionDocument(json: #"{"actions":[{"task":"やること","decided":true}]}"#)

        #expect(!ActionFormatter.markdown(from: document).contains("提案・検討中"))
    }

    @Test func 期限と発言時刻を添える() throws {
        let document = try ActionDocument(json: """
        {"actions":[{"task":"展開する","due":"来週月曜","at":"11:04:25","decided":true}]}
        """)

        let markdown = ActionFormatter.markdown(from: document)

        #expect(markdown.contains("来週月曜"))
        #expect(markdown.contains("11:04:25"))
    }

    @Test func 空でも壊れない() throws {
        #expect(try ActionDocument(json: #"{"actions":[]}"#).actions.isEmpty)
        #expect(ActionFormatter.markdown(from: ActionDocument(actions: [])).contains("アクションアイテムは"))
    }
}
