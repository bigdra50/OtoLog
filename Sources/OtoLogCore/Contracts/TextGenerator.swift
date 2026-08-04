import Foundation

// MARK: - TextGenerator

/// プロンプトからテキストを生成する。実装は差し替え可能（claude CLI、将来はローカルモデル等）。
public protocol TextGenerator: Sendable {
    func generate(prompt: String) async throws -> String
}

// MARK: - StreamingTextGenerator

/// 生成途中のテキスト（thinking 含む）を逐次観測できる generator。
/// ライブ進捗表示に使う。対応しない実装は TextGenerator のままでよい
public protocol StreamingTextGenerator: TextGenerator {
    func generate(
        prompt: String,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String
}

// MARK: - ReportedGeneration

/// 最終テキストと、生成中に起きたツール実行の問題の対。
public struct ReportedGeneration: Sendable {
    // MARK: Lifecycle

    public init(text: String, toolIssues: [ToolIssue]) {
        self.text = text
        self.toolIssues = toolIssues
    }

    // MARK: Public

    public let text: String
    public let toolIssues: [ToolIssue]
}

// MARK: - IssueReportingTextGenerator

/// ツール実行の問題（権限拒否・失敗）を最終テキストと併せて返せる generator。
/// 生成が完走してもツールが使えていないケースを、呼び出し側が警告として扱えるようにする
public protocol IssueReportingTextGenerator: StreamingTextGenerator {
    func generateReporting(
        prompt: String,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> ReportedGeneration
}
