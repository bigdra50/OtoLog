import Foundation
@testable import OtoLogApp
import Testing

/// 聞き取る言語の解決規則。自動検出のときだけ候補が使われる。
@MainActor struct AppSettingsRecognitionTests {
    // MARK: Internal

    @Test func 固定指定ならその言語だけを認識へ渡す() {
        withIsolatedSettings { settings in
            settings.localeIdentifier = "en-US"

            #expect(settings.resolvedRecognitionLocales == ["en-US"])
        }
    }

    @Test func 自動検出なら候補をそのまま渡す() {
        withIsolatedSettings { settings in
            settings.localeIdentifier = AppSettings.autoRecognitionLocale
            settings.recognitionCandidates = ["ja-JP", "ko-KR"]

            #expect(settings.resolvedRecognitionLocales == ["ja-JP", "ko-KR"])
        }
    }

    /// 候補を全部外されても記録は始められる。候補ゼロでエンジンが弾かれるより既定へ落とす
    @Test func 候補が空なら既定候補へ落とす() {
        withIsolatedSettings { settings in
            settings.localeIdentifier = AppSettings.autoRecognitionLocale
            settings.recognitionCandidates = []

            #expect(settings.resolvedRecognitionLocales == AppSettings.defaultRecognitionCandidates)
        }
    }

    @Test func 既定は日本語の固定で候補は英語と日本語() {
        withIsolatedSettings { settings in
            #expect(settings.localeIdentifier == "ja-JP")
            #expect(settings.recognitionCandidates == AppSettings.defaultRecognitionCandidates)
        }
    }

    // MARK: Private

    /// 実利用中の保存先を汚さないよう、専用 suite を作って捨てる
    private func withIsolatedSettings(_ body: (AppSettings) -> Void) {
        let suite = "OtoLogAppTests.recognition-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("テスト用の defaults を作れなかった")
            return
        }
        defer { defaults.removeSuite(named: suite) }
        body(AppSettings(defaults: defaults))
    }
}
