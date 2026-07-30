import Foundation
@preconcurrency import Translation

/// 実際に選べる翻訳先を Translation framework から引く。
public enum TranslationTargets {
    /// source から訳せて、かつ言語モデルが DL 済みのものだけを返す。
    ///
    /// 未 DL（status が supported）の言語を候補に出さないのは、
    /// 直接生成した TranslationSession から DL を要求できないため（canRequestDownloads は常に false）。
    /// 選ばせても notInstalled で失敗するだけなので、DL はシステム設定へ委ねる
    public static func installed(
        for sourceLocale: String,
        displayLocale: Locale = .current
    ) async -> [TranslationTarget] {
        let availability = LanguageAvailability()
        let source = Locale.Language(identifier: sourceLocale)
        var identifiers: [String] = []
        for candidate in await availability.supportedLanguages
            where await availability.status(from: source, to: candidate) == .installed {
            identifiers.append(candidate.maximalIdentifier)
        }
        return TranslationTargetList.make(identifiers: identifiers, displayLocale: displayLocale)
    }
}
