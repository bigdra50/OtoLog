import Foundation

// MARK: - TextGenerator

/// プロンプトからテキストを生成する。実装は差し替え可能（claude CLI、将来はローカルモデル等）。
public protocol TextGenerator: Sendable {
    func generate(prompt: String) async throws -> String
}
