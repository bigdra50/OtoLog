import Foundation
@testable import OtoLogApp
import Testing

/// 設定の書き込み先が注入した defaults に閉じていることを守るテスト。
/// ここが崩れると、レイアウト検証のためのテストが実利用中の保存先を書き換えてしまう。
@MainActor struct AppSettingsIsolationTests {
    @Test func 注入したdefaultsにだけ書きstandardを汚さない() {
        let suite = "OtoLogAppTests.isolation-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("テスト用の defaults を作れなかった")
            return
        }
        defer { defaults.removeSuite(named: suite) }

        let before = UserDefaults.standard.string(forKey: "saveDirectoryPath")
        let settings = AppSettings(defaults: defaults)
        settings.saveDirectoryPath = "~/tmp/otolog-isolation-check"

        #expect(defaults.string(forKey: "saveDirectoryPath") == "~/tmp/otolog-isolation-check")
        #expect(UserDefaults.standard.string(forKey: "saveDirectoryPath") == before)
    }

    @Test func 既定ではstandardから読む() {
        // 既定引数の経路が生きていること。読むだけで書かない
        let settings = AppSettings()
        #expect(!settings.saveDirectoryPath.isEmpty)
    }
}
