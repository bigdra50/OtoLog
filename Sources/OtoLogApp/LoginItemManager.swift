import Foundation
import ServiceManagement

/// ログイン時起動。LaunchAgent はオーディオアクセスが壊れる既知事例があるため
/// SMAppService のログインアイテム方式を使う。
enum LoginItemManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
