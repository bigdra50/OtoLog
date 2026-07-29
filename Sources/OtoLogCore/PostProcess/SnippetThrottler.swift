import Foundation

/// 生成デルタを蓄積し、一定間隔で末尾スニペットだけを流すスロットラ。
/// トークン単位の高頻度デルタをそのまま UI へ流すと無駄なので間引く。
final class SnippetThrottler: @unchecked Sendable {
    // MARK: Lifecycle

    init(
        interval: TimeInterval = 0.3,
        maxLength: Int = 140,
        onEmit: @escaping @Sendable (String) -> Void
    ) {
        self.interval = interval
        self.maxLength = maxLength
        self.onEmit = onEmit
    }

    // MARK: Internal

    func append(_ text: String) {
        let snippet: String? = lock.withLock {
            accumulated += text
            let now = Date()
            guard now.timeIntervalSince(lastEmit) >= interval else { return nil }
            lastEmit = now
            return String(accumulated.suffix(maxLength))
                .replacingOccurrences(of: "\n", with: " ")
        }
        if let snippet {
            onEmit(snippet)
        }
    }

    // MARK: Private

    private let interval: TimeInterval
    private let maxLength: Int
    private let onEmit: @Sendable (String) -> Void
    private let lock = NSLock()
    private var accumulated = ""
    private var lastEmit = Date.distantPast
}
