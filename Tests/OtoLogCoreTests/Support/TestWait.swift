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

// MARK: - OrderLog

/// 複数オブジェクトをまたぐ呼び出し順を記録する。
final class OrderLog: @unchecked Sendable {
    // MARK: Internal

    var entries: [String] {
        lock.withLock { _entries }
    }

    func append(_ entry: String) {
        lock.withLock { _entries.append(entry) }
    }

    // MARK: Private

    private let lock = NSLock()
    private var _entries: [String] = []
}
