import Foundation
@testable import OtoLogApp
import Testing

/// 無音で止まった記録を、戻ってきた利用者がポップオーバーで知るための文言。
/// 止めた時刻があれば、席を外している間の記録がどこまで残っているかが分かる
struct AutoStopNoticeTests {
    // MARK: Internal

    @Test func 無音の長さと止めた時刻を知らせる() {
        let stoppedAt = Date(timeIntervalSince1970: 1_785_303_120) // 2026-07-29 14:32 JST

        let message = AutoStopNotice.message(silence: .seconds(30 * 60), stoppedAt: stoppedAt, timeZone: jst)

        #expect(message == "無音が30分続いたため 14:32 に自動停止しました")
    }

    @Test func 分で割り切れない無音の長さは秒で知らせる() {
        let stoppedAt = Date(timeIntervalSince1970: 1_785_303_120)

        let message = AutoStopNotice.message(silence: .seconds(90), stoppedAt: stoppedAt, timeZone: jst)

        #expect(message == "無音が90秒続いたため 14:32 に自動停止しました")
    }

    // MARK: Private

    private let jst = TimeZone(identifier: "Asia/Tokyo")!
}
