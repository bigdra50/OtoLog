import Foundation

/// RecordingSession へ注入する sleep。待ち時間を記録し、hold 中は release されるまで戻らない。
/// 再起動前の待ちの最中に起きることを、実時間を待たずに再現する
final class ManualSleep: @unchecked Sendable {
    // MARK: Lifecycle

    init(holding: Bool = false) {
        isHolding = holding
    }

    // MARK: Internal

    /// 呼ばれた順の待ち時間
    var requestedDurations: [Duration] {
        lock.withLock { requested }
    }

    /// release を待っている呼び出しの数
    var waitingCount: Int {
        lock.withLock { waiters.count }
    }

    /// 戻り終えた呼び出しの数（release で戻ったものを含む）
    var returnedCount: Int {
        lock.withLock { returned }
    }

    /// タスクのキャンセルでは戻らない。待つ間に記録が畳まれても、待ち明けの確認まで進む場合を再現するため
    func sleep(for duration: Duration) async {
        await withCheckedContinuation { continuation in
            // 記録と待ちの登録を同じロックで行う。間に release が挟まると、登録した待ちが戻されずに残る
            let waits = lock.withLock {
                requested.append(duration)
                if isHolding {
                    waiters.append(continuation)
                }
                return isHolding
            }
            if !waits {
                continuation.resume()
            }
        }
        lock.withLock { returned += 1 }
    }

    /// 待っている呼び出しをすべて戻し、以降の呼び出しは待たせない
    func release() {
        let pending = lock.withLock {
            isHolding = false
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pending {
            waiter.resume()
        }
    }

    // MARK: Private

    private let lock = NSLock()
    private var isHolding: Bool
    private var requested: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var returned = 0
}
