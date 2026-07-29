import Foundation

// MARK: - TextGenerator

/// プロンプトからテキストを生成する。実装は差し替え可能（claude CLI、将来はローカルモデル等）。
public protocol TextGenerator: Sendable {
    func generate(prompt: String) async throws -> String
}

// MARK: - StreamingTextGenerator

/// 生成途中のテキスト（thinking 含む）を逐次観測できる generator。
/// ライブ進捗表示に使う。対応しない実装は TextGenerator のままでよい
public protocol StreamingTextGenerator: TextGenerator {
    func generate(
        prompt: String,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String
}
