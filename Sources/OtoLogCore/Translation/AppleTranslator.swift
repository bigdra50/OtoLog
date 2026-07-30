import Foundation
@preconcurrency import Translation

/// Translation framework（オンデバイス）による翻訳。
/// TranslationSession は非 Sendable なので actor に閉じ込め、所有権を1箇所に固定する。
public actor AppleTranslator: Translator {
    // MARK: Lifecycle

    /// 同一言語ペアと解釈できないロケールでは nil を返す。呼び出し側は翻訳なしで動く。
    ///
    /// ロケール文字列は正規化せずそのまま Locale.Language へ渡す。
    /// システム既定は supportedLanguages に無い組み合わせ（en-Latn-JP 等）になり得るが、
    /// framework 側が en-Latn-US へ解決する。languageCode で候補へ寄せ直すと
    /// 別地域（en-Latn-IN 等）を掴んで訳文が劣化する
    public init?(sourceLocale: String, targetLocale: String) {
        let source = Locale.Language(identifier: sourceLocale)
        let target = Locale.Language(identifier: targetLocale)
        guard let sourceCode = source.languageCode?.identifier,
              let targetCode = target.languageCode?.identifier,
              !sourceCode.isEmpty, !targetCode.isEmpty,
              sourceCode != targetCode
        else { return nil }
        self.source = source
        self.target = target
    }

    // MARK: Public

    public func translate(_ text: String) async throws -> TranslatedText {
        let response = try await currentSession().translate(text)
        return TranslatedText(
            text: response.targetText,
            locale: response.targetLanguage.maximalIdentifier
        )
    }

    // MARK: Private

    private let source: Locale.Language
    private let target: Locale.Language
    private var session: TranslationSession?

    /// セッションは記録セッションをまたいで使い回す。作り直すたびに
    /// モデルのウォームアップ（初回約5秒）が入り、最初のセグメントの訳が遅れるため
    private func currentSession() -> TranslationSession {
        if let session { return session }
        // 直接生成したセッションはモデルを DL できない（canRequestDownloads は常に false）。
        // 未 DL の言語は notInstalled で throw されるので、選択肢は DL 済みに絞る
        let created = TranslationSession(installedSource: source, target: target)
        session = created
        return created
    }
}
