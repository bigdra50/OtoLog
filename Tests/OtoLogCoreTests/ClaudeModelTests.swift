import Foundation
@testable import OtoLogCore
import Testing

struct ClaudeModelTests {
    /// タスク属性 → claude -p 引数の合成規則の固定。
    /// --tools の variadic 指定（WebSearch WebFetch）は実 CLI v2.1.220 で動作確認済み
    @Test func composesArgumentsForModelAndWebCombinations() {
        let overrides: [String] = [
            "--setting-sources", "",
            "--settings", ClaudeCLIGenerator.overrideSettingsJSON,
            "--system-prompt", ClaudeCLIGenerator.systemPrompt,
        ]
        #expect(ClaudeCLIGenerator.arguments(model: nil, allowWebResearch: false) == [
            "-p", "--output-format", "text", "--tools", "",
            "--no-session-persistence", "--disable-slash-commands",
        ] + overrides)
        #expect(ClaudeCLIGenerator.arguments(model: .haiku, allowWebResearch: false) == [
            "-p", "--output-format", "text", "--tools", "",
            "--no-session-persistence", "--disable-slash-commands",
        ] + overrides + ["--model", "haiku"])
        #expect(ClaudeCLIGenerator.arguments(model: .sonnet, allowWebResearch: true) == [
            "-p", "--output-format", "text",
            "--tools", "WebSearch", "WebFetch",
            "--allowedTools", "WebSearch", "WebFetch",
            "--no-session-persistence", "--disable-slash-commands",
        ] + overrides + ["--model", "sonnet"])
        #expect(ClaudeCLIGenerator.arguments(model: .opus, allowWebResearch: true).contains("opus"))
    }

    /// --tools はツールを使える状態にするだけで、非対話実行の許可までは与えない。
    /// --allowedTools が無いと「WebFetch ツールの使用許可が必要です」で弾かれ、
    /// 用語集や参考資料が Web 検証なしのまま生成される
    @Test func webResearchGrantsPermissionNotJustAvailability() {
        let withWeb = ClaudeCLIGenerator.arguments(model: .sonnet, allowWebResearch: true)
        #expect(withWeb.contains("--allowedTools"))

        let withoutWeb = ClaudeCLIGenerator.arguments(model: .sonnet, allowWebResearch: false)
        #expect(!withoutWeb.contains("--allowedTools"))
    }

    /// 既定引数は「モデル指定なし・Web なし」の合成結果と一致し続ける
    @Test func defaultArgumentsMatchComposition() {
        #expect(ClaudeCLIGenerator.defaultArguments
            == ClaudeCLIGenerator.arguments(model: nil, allowWebResearch: false))
    }

    /// スキーマ付きのタスクは --json-schema を渡す。
    /// Markdown を書かせてパースすると体裁の揺れを拾いきれない
    @Test func passesJSONSchemaWhenTemplateDefinesOne() {
        let schema = #"{"type":"object"}"#

        let args = ClaudeCLIGenerator.arguments(model: .sonnet, allowWebResearch: false, jsonSchema: schema)

        #expect(args.contains("--json-schema"))
        #expect(args.contains(schema))
    }

    @Test func omitsJSONSchemaWhenAbsent() {
        #expect(!ClaudeCLIGenerator.arguments(model: .sonnet, allowWebResearch: false).contains("--json-schema"))
    }
}
