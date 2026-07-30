import Foundation
@testable import OtoLogCore
import Testing

struct AppleTranslatorTests {
    /// 翻訳先が認識言語と同じなら翻訳器を作らない。
    /// Translation は同一言語ペアを unsupportedLanguagePairing で弾くため、要求前に落とす
    @Test func returnsNilWhenLanguagesAreTheSame() {
        #expect(AppleTranslator(sourceLocale: "ja-JP", targetLocale: "ja-JP") == nil)
        #expect(AppleTranslator(sourceLocale: "ja-JP", targetLocale: "ja") == nil)
        // 地域違いも同一言語として扱われる（en-US -> en-GB は翻訳できない）
        #expect(AppleTranslator(sourceLocale: "en-US", targetLocale: "en-GB") == nil)
    }

    @Test func buildsTranslatorForDifferentLanguages() {
        #expect(AppleTranslator(sourceLocale: "ja-JP", targetLocale: "en-US") != nil)
        // システム既定は supportedLanguages に無い組み合わせ（en-Latn-JP 等）にもなるが、
        // 正規化せずそのまま渡す。framework 側が解決する
        #expect(AppleTranslator(sourceLocale: "ja-JP", targetLocale: "en-Latn-JP") != nil)
    }

    @Test func returnsNilForUnparsableLocale() {
        #expect(AppleTranslator(sourceLocale: "", targetLocale: "en-US") == nil)
        #expect(AppleTranslator(sourceLocale: "ja-JP", targetLocale: "") == nil)
    }
}
