import Foundation

/// テストから進める時計。RecordingSession の now に渡し、中断の間隔を実時間に頼らず作る
final class TestClock: @unchecked Sendable {
    // MARK: Lifecycle

    init(now: Date = Date(timeIntervalSince1970: 1_785_297_600)) {
        current = now
    }

    // MARK: Internal

    var now: Date {
        lock.withLock { current }
    }

    func advance(by duration: Duration) {
        lock.withLock { current = current.addingTimeInterval(duration / .seconds(1)) }
    }

    // MARK: Private

    private let lock = NSLock()
    private var current: Date
}
