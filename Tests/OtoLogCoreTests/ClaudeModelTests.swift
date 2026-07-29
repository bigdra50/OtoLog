import Foundation
@testable import OtoLogCore
import Testing

struct ClaudeModelTests {
    /// タスク属性 → claude -p 引数の合成規則の固定。
    /// --tools の variadic 指定（WebSearch WebFetch）は実 CLI v2.1.220 で動作確認済み
    @Test func composesArgumentsForModelAndWebCombinations() {
        #expect(ClaudeCLIGenerator.arguments(model: nil, allowWebResearch: false) == [
            "-p", "--output-format", "text", "--tools", "",
            "--no-session-persistence", "--disable-slash-commands",
        ])
        #expect(ClaudeCLIGenerator.arguments(model: .haiku, allowWebResearch: false) == [
            "-p", "--output-format", "text", "--tools", "",
            "--no-session-persistence", "--disable-slash-commands", "--model", "haiku",
        ])
        #expect(ClaudeCLIGenerator.arguments(model: .sonnet, allowWebResearch: true) == [
            "-p", "--output-format", "text", "--tools", "WebSearch", "WebFetch",
            "--no-session-persistence", "--disable-slash-commands", "--model", "sonnet",
        ])
        #expect(ClaudeCLIGenerator.arguments(model: .opus, allowWebResearch: true).contains("opus"))
    }

    /// 既定引数は「モデル指定なし・Web なし」の合成結果と一致し続ける
    @Test func defaultArgumentsMatchComposition() {
        #expect(ClaudeCLIGenerator.defaultArguments
            == ClaudeCLIGenerator.arguments(model: nil, allowWebResearch: false))
    }
}
