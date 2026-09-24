import Foundation

/// 非同期の副作用が観測されるまでポーリングする。タイムアウトしたら false。
func eventually(
    timeout: Duration = .seconds(2),
    interval: Duration = .milliseconds(10),
    _ predicate: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: interval)
    }
    return await predicate()
}
