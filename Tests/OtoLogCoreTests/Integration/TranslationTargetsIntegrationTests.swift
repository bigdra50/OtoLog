import Foundation
@testable import OtoLogCore
import Testing
import Translation

/// 実 Translation framework から翻訳先候補を引く統合テスト。OTOLOG_INTEGRATION=1 のときだけ実行される。
@Suite(.serialized, .timeLimit(.minutes(5)), .enabled(if: ProcessInfo.processInfo.environment["OTOLOG_INTEGRATION"] == "1")) struct TranslationTargetsIntegrationTests {
    @Test func listsInstalledTargetsForJapanese() async {
        let targets = await TranslationTargets.installed(
            for: "ja-JP", displayLocale: Locale(identifier: "ja-JP")
        )

        #expect(!targets.isEmpty)
        // 認識言語と同じ言語は翻訳できないので候補に出ない
        #expect(!targets.contains { $0.identifier.hasPrefix("ja") })
        // 表示名は畳まれている（「英語（ラテン文字、アメリカ合衆国）」にならない）
        #expect(targets.allSatisfy { !$0.displayName.contains("ラテン文字") })
    }

    /// 候補はそのまま翻訳器へ渡せる（DL 済みだけを返す契約）
    @Test func everyListedTargetIsUsable() async throws {
        let targets = await TranslationTargets.installed(for: "ja-JP")
        let first = try #require(targets.first)

        let translator = try #require(AppleTranslator(
            sourceLocale: "ja-JP", targetLocale: first.identifier
        ))
        let result = try await translator.translate("これは候補の疎通確認です。")

        #expect(!result.text.isEmpty)
    }
}
