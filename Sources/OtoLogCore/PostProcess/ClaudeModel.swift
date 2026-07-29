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
    /// --tools の variadic 指定（WebSearch WebFetch）は実 CLI v2.1.220 で動作確認済み
    static func arguments(model: ClaudeModel?, allowWebResearch: Bool) -> [String] {
        var arguments = ["-p", "--output-format", "text"]
        arguments += allowWebResearch ? ["--tools", "WebSearch", "WebFetch"] : ["--tools", ""]
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
