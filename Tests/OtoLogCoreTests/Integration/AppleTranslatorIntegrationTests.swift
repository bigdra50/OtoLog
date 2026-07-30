import Foundation
@testable import OtoLogCore
import Testing
import Translation

/// 実 Translation framework を使う統合テスト。OTOLOG_INTEGRATION=1 のときだけ実行される。
/// 翻訳はオンデバイスだが、言語モデルが未 DL の環境では notInstalled で失敗する。
@Suite(.serialized, .timeLimit(.minutes(5)), .enabled(if: ProcessInfo.processInfo.environment["OTOLOG_INTEGRATION"] == "1")) struct AppleTranslatorIntegrationTests {
    @Test func translatesJapaneseIntoEnglish() async throws {
        let sut = try #require(AppleTranslator(sourceLocale: "ja-JP", targetLocale: "en-US"))

        let result = try await sut.translate("本日はよろしくお願いします。")

        #expect(!result.text.isEmpty)
        #expect(result.locale.hasPrefix("en"))
    }

    /// システム既定は supportedLanguages に無い組み合わせ（en-Latn-JP 等）になり得る。
    /// 正規化せず渡して framework 側の解決に委ねる方針が実環境で通ることを確かめる
    @Test func acceptsSystemDefaultLanguageWithoutNormalization() async throws {
        let system = Locale.current.language.maximalIdentifier
        guard let sut = AppleTranslator(sourceLocale: "ja-JP", targetLocale: system) else {
            // システム既定が日本語なら翻訳器自体が作られない（同一言語ペア）
            return
        }

        let result = try await sut.translate("システム既定の言語へ訳せるかを確かめる。")

        #expect(!result.text.isEmpty)
        // 要求した識別子そのものではなく、解決後の言語が返る
        #expect(result.locale.hasPrefix(Locale.current.language.languageCode?.identifier ?? ""))
    }

    /// セッションを使い回すため、2回目以降はウォームアップ（初回約5秒）が入らない
    @Test func reusesSessionAcrossCalls() async throws {
        let sut = try #require(AppleTranslator(sourceLocale: "ja-JP", targetLocale: "en-US"))
        _ = try await sut.translate("ウォームアップ。")

        let started = Date()
        _ = try await sut.translate("二回目の翻訳は速い。")

        #expect(Date().timeIntervalSince(started) < 3.0)
    }

    /// 未 DL の言語は notInstalled で throw される。設定の選択肢を DL 済みに絞る根拠
    @Test func throwsWhenTargetLanguageIsNotInstalled() async throws {
        let availability = LanguageAvailability()
        let source = Locale.Language(identifier: "ja-JP")
        let candidates = await availability.supportedLanguages
        var notInstalled: Locale.Language?
        for candidate in candidates
            where await availability.status(from: source, to: candidate) == .supported {
            notInstalled = candidate
            break
        }
        guard let notInstalled else { return } // 全言語 DL 済みの環境ではスキップ

        let sut = try #require(AppleTranslator(
            sourceLocale: "ja-JP",
            targetLocale: notInstalled.maximalIdentifier
        ))

        await #expect(throws: (any Error).self) {
            try await sut.translate("未ダウンロードの言語へ訳す。")
        }
    }
}
