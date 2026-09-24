import Foundation
@testable import OtoLogApp
import OtoLogCore
import Testing

/// SessionEvent を AppState へ映すことと、記録の開始に設定を渡すことを守るテスト。
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

    // MARK: 無音で自動停止する設定

    /// otolog-devtool ctl start で始めた記録も、ポップオーバーと同じ設定で無音を見張る。見張りは15秒ごとに確かめる
    @Test func ctlから始めた記録も設定に従って無音を見張る() async {
        let fixture = RecordingCoordinatorFixture()
        fixture.settings.silenceAutoStopMinutes = 10

        let response = await fixture.coordinator.controlStart()

        #expect(response.ok)
        #expect(await eventually { fixture.sleeps.requestedDurations == [.seconds(15)] })
        await fixture.tearDown()
    }

    @Test func オフならctlから始めた記録は無音を見張らない() async {
        let fixture = RecordingCoordinatorFixture()
        fixture.settings.silenceAutoStopMinutes = 0

        let response = await fixture.coordinator.controlStart()
        // 見張りがあれば、止め終えるまでの間に最初の待ちへ入っている
        await fixture.session.stop()

        #expect(response.ok)
        #expect(fixture.sleeps.requestedDurations.isEmpty)
        await fixture.tearDown()
    }

    @Test func ポップオーバーから始めた記録も設定に従って無音を見張る() async {
        let fixture = RecordingCoordinatorFixture()
        fixture.settings.silenceAutoStopMinutes = 10

        fixture.coordinator.toggle()

        #expect(await eventually { fixture.sleeps.requestedDurations == [.seconds(15)] })
        await fixture.tearDown()
    }

    @Test func オフならポップオーバーから始めた記録は無音を見張らない() async {
        let fixture = RecordingCoordinatorFixture()
        fixture.settings.silenceAutoStopMinutes = 0

        fixture.coordinator.toggle()
        #expect(await eventually { await fixture.session.state == .recording })
        // 見張りがあれば、止め終えるまでの間に最初の待ちへ入っている
        await fixture.session.stop()

        #expect(fixture.sleeps.requestedDurations.isEmpty)
        await fixture.tearDown()
    }
}
