import Foundation
@testable import OtoLogApp
import Testing

/// 無音での自動停止の設定。未設定なら30分で止め、0 はオフとして区別して残す。
@MainActor struct AppSettingsSilenceAutoStopTests {
    // MARK: Internal

    /// 会議の後に止め忘れた記録を想定し、設定に触れていなくても30分の無音で止める
    @Test func 既定は30分の無音で止める() {
        withIsolatedSettings { settings in
            #expect(settings.silenceAutoStopMinutes == 30)
            #expect(settings.silenceTimeout == .seconds(30 * 60))
        }
    }

    @Test func 選択肢はオフと10分15分30分60分() {
        #expect(AppSettings.silenceAutoStopChoices == [0, 10, 15, 30, 60])
    }

    @Test func 選んだ分数は注入したdefaultsへ永続化される() {
        withIsolatedSettings { settings, defaults in
            settings.silenceAutoStopMinutes = 15

            #expect(defaults.integer(forKey: "silenceAutoStopMinutes") == 15)
            // 同じ defaults から読み直しても復元される
            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.silenceAutoStopMinutes == 15)
            #expect(reloaded.silenceTimeout == .seconds(15 * 60))
        }
    }

    /// オフ（0）は未設定と区別して読み直す。0 を既定の30分へ戻すと、オフにしても止まってしまう
    @Test func オフは読み直してもオフのままで止める時間を渡さない() {
        withIsolatedSettings { settings, defaults in
            settings.silenceAutoStopMinutes = 0

            #expect(settings.silenceTimeout == nil)
            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.silenceAutoStopMinutes == 0)
            #expect(reloaded.silenceTimeout == nil)
        }
    }

    // MARK: Private

    private func withIsolatedSettings(_ body: (AppSettings) -> Void) {
        withIsolatedSettings { settings, _ in body(settings) }
    }

    /// 実利用中の保存先を汚さないよう、専用 suite を作って捨てる
    private func withIsolatedSettings(_ body: (AppSettings, UserDefaults) -> Void) {
        let suite = "OtoLogAppTests.silence-auto-stop-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("テスト用の defaults を作れなかった")
            return
        }
        defer { defaults.removeSuite(named: suite) }
        body(AppSettings(defaults: defaults), defaults)
    }
}
