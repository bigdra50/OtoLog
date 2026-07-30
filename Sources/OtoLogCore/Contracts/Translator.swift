import Foundation

// MARK: - TranslatedText

/// 翻訳結果。
public struct TranslatedText: Sendable, Equatable {
    // MARK: Lifecycle

    public init(text: String, locale: String) {
        self.text = text
        self.locale = locale
    }

    // MARK: Public

    public let text: String
    /// 実際に訳された言語の BCP-47。要求した言語と一致するとは限らない
    /// （システム既定の en-Latn-JP を要求すると en-Latn-US で返る）ため、要求値ではなく結果を持つ
    public let locale: String
}

// MARK: - Translator

/// 確定セグメントの本文を別の言語へ訳す。
/// 翻訳先が認識言語と同じときは実装を生成しない規約（同一言語ペアは翻訳できない）なので、
/// 「訳さない」は nil の Translator で表し、このメソッドは失敗時に throw する。
public protocol Translator: Sendable {
    func translate(_ text: String) async throws -> TranslatedText
}
