import Foundation
@testable import OtoLogApp
import Testing

/// 翻訳設定の既定値と、翻訳先の解決規則。
@MainActor struct AppSettingsTranslationTests {
    // MARK: Internal

    /// 既存ユーザーの挙動を変えないよう、翻訳は既定でオフ
    @Test func 既定は翻訳オフでシステム既定を指す() {
        withIsolatedSettings { settings in
            #expect(settings.translationEnabled == false)
            #expect(settings.translationTargetIdentifier == AppSettings.systemTranslationTarget)
        }
    }

    /// システム既定は supportedLanguages に無い組み合わせ（en-Latn-JP 等）にもなるが、
    /// 正規化せず framework へ渡す。言語コードで候補へ寄せ直すと別地域を掴んで訳文が劣化する
    @Test func システム既定は現在のロケールの言語へ解決される() {
        withIsolatedSettings { settings in
            #expect(settings.resolvedTranslationTarget == Locale.current.language.maximalIdentifier)
        }
    }

    @Test func 明示指定した翻訳先はそのまま使う() {
        withIsolatedSettings { settings in
            settings.translationTargetIdentifier = "zh-Hans-CN"
            #expect(settings.resolvedTranslationTarget == "zh-Hans-CN")
        }
    }

    @Test func 翻訳設定は注入したdefaultsへ永続化される() {
        withIsolatedSettings { settings, defaults in
            settings.translationEnabled = true
            settings.translationTargetIdentifier = "en-US"

            #expect(defaults.bool(forKey: "translationEnabled"))
            #expect(defaults.string(forKey: "translationTargetIdentifier") == "en-US")
            // 同じ defaults から読み直しても復元される
            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.translationEnabled)
            #expect(reloaded.translationTargetIdentifier == "en-US")
        }
    }

    // MARK: Private

    private func withIsolatedSettings(_ body: (AppSettings) -> Void) {
        withIsolatedSettings { settings, _ in body(settings) }
    }

    /// 実利用中の保存先を汚さないよう、専用 suite を作って捨てる
    private func withIsolatedSettings(_ body: (AppSettings, UserDefaults) -> Void) {
        let suite = "OtoLogAppTests.translation-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("テスト用の defaults を作れなかった")
            return
        }
        defer { defaults.removeSuite(named: suite) }
        body(AppSettings(defaults: defaults), defaults)
    }
}
