import Foundation
@testable import OtoLogApp
import OtoLogCore
import Testing

/// SessionEvent を AppState へ映す RecordingCoordinator の振る舞いを守るテスト。
@MainActor struct RecordingCoordinatorTests {
    /// 無音で自動停止した後に、停止と同じ閉じ方で続けて流れるイベント
    nonisolated static let closingEvents: [SessionEvent] = [
        .stateChanged(.stopping),
        .sessionFinished(SessionRef(
            directoryName: "2026-09-24/1300", title: nil, startedAt: Date(timeIntervalSince1970: 1_790_222_400)
        )),
        .stateChanged(.idle),
    ]

    // MARK: 無音で自動停止した知らせ

    /// 無音の見張りが止めたことを、無音の長さとともにポップオーバーへ出す
    @Test func 無音で自動停止したら知らせを出す() async {
        let fixture = RecordingCoordinatorFixture()

        fixture.coordinator.apply(.autoStopped(silence: .seconds(30 * 60)))

        // 止めた時刻は apply した時点の時計で決まるため、無音の長さまでを確かめる
        #expect(fixture.state.autoStopNotice?.hasPrefix("無音が30分続いたため") == true)
        await fixture.tearDown()
    }

    /// 知らせは止まった後に戻ってきた利用者が見るものなので、閉じ終えても消さない
    @Test(arguments: closingEvents) func 自動停止に続いて閉じる間は知らせを消さない(event: SessionEvent) async {
        let fixture = RecordingCoordinatorFixture()
        fixture.coordinator.apply(.autoStopped(silence: .seconds(30 * 60)))
        let notice = fixture.state.autoStopNotice

        fixture.coordinator.apply(event)

        #expect(notice != nil)
        #expect(fixture.state.autoStopNotice == notice)
        await fixture.tearDown()
    }

    /// 次の記録を始めたところ（.preparing）で消す。新しい記録の間まで前の記録の知らせを出し続けない
    @Test func 次の記録を始めたら知らせを消す() async {
        let fixture = RecordingCoordinatorFixture()
        fixture.coordinator.apply(.autoStopped(silence: .seconds(30 * 60)))
        #expect(fixture.state.autoStopNotice != nil)

        fixture.coordinator.apply(.stateChanged(.preparing))

        #expect(fixture.state.autoStopNotice == nil)
        await fixture.tearDown()
    }
}
