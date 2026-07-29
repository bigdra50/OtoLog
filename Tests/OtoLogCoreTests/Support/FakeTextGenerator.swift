import Foundation
@testable import OtoLogCore

/// 受け取ったプロンプトを記録し、固定結果かエラーを返す TextGenerator。
final class FakeTextGenerator: TextGenerator, @unchecked Sendable {
    // MARK: Lifecycle

    init(result: String = "", delay: Duration = .zero) {
        _result = result
        self.delay = delay
    }

    // MARK: Internal

    var result: String {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }

    var errorToThrow: (any Error)? {
        get { lock.withLock { _errorToThrow } }
        set { lock.withLock { _errorToThrow = newValue } }
    }

    var receivedPrompts: [String] {
        lock.withLock { _receivedPrompts }
    }

    func generate(prompt: String) async throws -> String {
        lock.withLock { _receivedPrompts.append(prompt) }
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        if let error = errorToThrow {
            throw error
        }
        return result
    }

    // MARK: Private

    private let lock = NSLock()
    private let delay: Duration
    private var _result: String
    private var _errorToThrow: (any Error)?
    private var _receivedPrompts: [String] = []
}
