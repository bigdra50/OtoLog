import Foundation
@testable import OtoLogCore
import Testing

/// 取り消せない待ち（タスクの終わり、記録を閉じる処理）に上限を付ける
struct AwaitAtMostTests {
    @Test func returnsTrueWhenTheOperationEndsFirst() async {
        let timeout = ManualSleep(holding: true)

        let ended = await awaitAtMost(.seconds(1), sleep: { await timeout.sleep(for: $0) }) {}

        #expect(ended)
    }

    /// 上限で戻っても、待っていた処理は止めずに続けさせる
    @Test func returnsFalseAtTheTimeoutWithoutStoppingTheOperation() async {
        let operation = ManualSleep(holding: true)
        let finished = OrderLog()

        let ended = await awaitAtMost(.seconds(1), sleep: { _ in }) {
            await operation.sleep(for: .zero)
            finished.append("finished")
        }

        #expect(!ended)
        operation.release()
        #expect(await eventually { finished.entries == ["finished"] })
    }
}
