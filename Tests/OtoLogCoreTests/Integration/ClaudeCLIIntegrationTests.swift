import Foundation
@testable import OtoLogCore
import Testing

/// 実 claude -p を呼ぶ統合テスト。目的はフラグの互換確認（改名・非推奨化の検知）。
/// 課金が発生するため OTOLOG_CLAUDE_INTEGRATION=1 のときだけ実行される（mise run test:claude）。
/// LLM 出力の揺れに依存しないよう、アサートは非空のみ
@Suite(
    .serialized,
    .timeLimit(.minutes(5)),
    .enabled(if: ProcessInfo.processInfo.environment["OTOLOG_CLAUDE_INTEGRATION"] == "1")
) struct ClaudeCLIIntegrationTests {
    @Test func generatesTextViaRealClaudeCLI() async throws {
        let path = ProcessInfo.processInfo.environment["OTOLOG_CLAUDE_PATH"] ?? "~/.local/bin/claude"
        let generator = ClaudeCLIGenerator(
            executableURL: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        )
        let output = try await generator.generate(prompt: "「OK」とだけ出力してください。")
        #expect(!output.isEmpty)
    }
}
