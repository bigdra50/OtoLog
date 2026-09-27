import Foundation

/// operation が終わるまで待つ。先に timeout が過ぎたら、待つのをやめて false を返す。
///
/// 取り消せない待ち（タスクの終わり、記録を閉じる処理）に上限を付けるために使う。
/// timeout で戻っても operation は止めない。止めてよいかは呼び出し側が決める
public func awaitAtMost(
    _ timeout: Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    _ operation: @escaping @Sendable () async -> Void
) async -> Bool {
    await withCheckedContinuation { continuation in
        let outcome = FirstOutcome(continuation)
        Task {
            await operation()
            outcome.settle(true)
        }
        Task {
            try? await sleep(timeout)
            outcome.settle(false)
        }
    }
}

// MARK: - FirstOutcome

/// 先に届いた結果だけで continuation を再開する
private final class FirstOutcome: @unchecked Sendable {
    // MARK: Lifecycle

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    // MARK: Internal

    func settle(_ value: Bool) {
        let pending = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }

    // MARK: Private

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
}
