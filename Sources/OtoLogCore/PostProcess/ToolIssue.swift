import Foundation

/// 生成中に起きたツール実行の問題。
/// 生成は完走してもツールが使えていない（Web 検索なしの用語集など）ことがあり、
/// それを「成功」と区別して表示するために最終テキストと別建てで運ぶ。
public struct ToolIssue: Sendable, Equatable, Codable {
    // MARK: Lifecycle

    public init(toolName: String, kind: Kind) {
        self.toolName = toolName
        self.kind = kind
    }

    // MARK: Public

    public enum Kind: String, Sendable, Codable {
        /// ツールの使用が許可されなかった（--allowedTools の欠落等）
        case permissionDenied
        /// 実行したが失敗した（ネットワークエラー等）
        case executionFailed
    }

    public let toolName: String
    public let kind: Kind

    /// UI と meta.json の警告に使う利用者向け文言
    public var userMessage: String {
        switch kind {
        case .permissionDenied:
            "\(toolName) の使用が許可されず実行できませんでした"
        case .executionFailed:
            "\(toolName) の実行に失敗した箇所があります"
        }
    }
}
