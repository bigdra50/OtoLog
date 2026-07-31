import Foundation

// MARK: - ClaudeModel

/// パイプラインのタスクごとに指定する claude のモデル階級。
/// rawValue は claude CLI の --model に渡すエイリアス。
public enum ClaudeModel: String, Sendable, Codable, CaseIterable {
    case haiku
    case sonnet
    case opus
}

// MARK: - 引数合成

public extension ClaudeCLIGenerator {
    /// タスク属性から claude -p の引数列を合成する。
    /// defaultArguments == arguments(model: nil, allowWebResearch: false) の関係をテストで固定している。
    ///
    /// --tools はツールを使える状態にするだけで、実行の許可までは与えない。
    /// 非対話（-p）では許可を尋ねる相手がいないので、--allowedTools を併記しないと
    /// 「WebFetch ツールの使用許可が必要です」で弾かれ、
    /// 用語集や参考資料が Web 検証なしのまま出来上がる（実 CLI v2.1.220 で確認）
    static func arguments(model: ClaudeModel?, allowWebResearch: Bool) -> [String] {
        var arguments = ["-p", "--output-format", "text"]
        arguments += allowWebResearch
            ? ["--tools", "WebSearch", "WebFetch", "--allowedTools", "WebSearch", "WebFetch"]
            : ["--tools", ""]
        arguments += ["--no-session-persistence", "--disable-slash-commands"]
        // 設定遮断と上書きの理由は defaultArguments / overrideSettingsJSON のコメント参照
        arguments += ["--setting-sources", ""]
        arguments += ["--settings", overrideSettingsJSON]
        arguments += ["--system-prompt", systemPrompt]
        if let model {
            arguments += ["--model", model.rawValue]
        }
        return arguments
    }
}
