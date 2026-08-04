import Foundation
@testable import OtoLogCore

// MARK: - FakeTextGenerator

/// 受け取ったプロンプトを記録し、固定結果かエラーを返す TextGenerator。
/// partials を設定するとストリーミング版でその断片が順に流れる。
final class FakeTextGenerator: StreamingTextGenerator, @unchecked Sendable {
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

    var partials: [String] {
        get { lock.withLock { _partials } }
        set { lock.withLock { _partials = newValue } }
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

    func generate(
        prompt: String,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        for partial in partials {
            onPartial(partial)
        }
        return try await generate(prompt: prompt)
    }

    // MARK: Private

    private let lock = NSLock()
    private let delay: Duration
    private var _result: String
    private var _errorToThrow: (any Error)?
    private var _receivedPrompts: [String] = []
    private var _partials: [String] = []
    private var _toolIssues: [ToolIssue] = []
}

// MARK: IssueReportingTextGenerator

extension FakeTextGenerator: IssueReportingTextGenerator {
    var toolIssues: [ToolIssue] {
        get { lock.withLock { _toolIssues } }
        set { lock.withLock { _toolIssues = newValue } }
    }

    func generateReporting(
        prompt: String,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> ReportedGeneration {
        let text = try await generate(prompt: prompt, onPartial: onPartial)
        return ReportedGeneration(text: text, toolIssues: toolIssues)
    }
}
