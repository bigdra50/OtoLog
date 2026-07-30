import Foundation
@testable import OtoLogCore
import Testing

/// 判定材料は実機で採取した認識結果をそのまま使う。
/// 誤ったロケールの認識器はローマ字化したり別言語の単語を混ぜたりするので、
/// 「認識器のロケールと判定言語が一致するか」で選り分けられる。
struct LanguageDeciderTests {
    /// 英語音声を en-US と ja-JP の認識器へ同時に流したときの実測出力
    let englishSpoken = [
        (
            locale: "en-US",
            text: "Today, I want to talk about how we approach Vauxhall rendering its scale, and why the Naivak tree approach breaks down."
        ),
        (
            locale: "ja-JP",
            text: "Today Iant toトーク abot howeアプローチ box orenderig scale andhy the Nowactryprach breaks down。"
        ),
    ]

    /// 日本語音声の実測出力。en-US 側はローマ字化される
    let japaneseSpoken = [
        (
            locale: "en-US",
            text: "Hong jitsuba, bok seudendaringu no daikibokanituite, ohanashimas. Boktuli, bahatanshimas."
        ),
        (
            locale: "ja-JP",
            text: "本日はボクセルレンダリングの大規模化についてお話しします。ボクツリーは破綻します。"
        ),
    ]

    @Test func picksEnglishForEnglishSpeech() {
        #expect(LanguageDecider.decide(englishSpoken) == "en-US")
    }

    @Test func picksJapaneseForJapaneseSpeech() {
        #expect(LanguageDecider.decide(japaneseSpoken) == "ja-JP")
    }

    /// 材料が短いうちは決めない。誤判定して認識器を絞るより待つほうがましなので
    @Test func waitsWhileTextIsTooShort() {
        #expect(LanguageDecider.decide([(locale: "ja-JP", text: "本日は")]) == nil)
        #expect(LanguageDecider.decide([(locale: "en-US", text: "Today I")]) == nil)
    }

    @Test func returnsNilForEmptyInput() {
        #expect(LanguageDecider.decide([]) == nil)
        #expect(LanguageDecider.decide([(locale: "en-US", text: "")]) == nil)
    }

    /// 中国語は NLLanguage が zh-Hans / zh-Hant を返す一方、ロケールの言語コードは zh。
    /// 素朴に文字列比較すると一致せず、中国語だけ永久に判定できなくなる
    @Test func matchesChineseAcrossScriptVariants() {
        let spoken = [
            (locale: "zh-CN", text: "今天我想谈谈我们如何大规模地处理体素渲染，以及为什么朴素的八叉树方法会失效。"),
        ]

        #expect(LanguageDecider.decide(spoken) == "zh-CN")
    }

    /// 一致する候補が無ければ決めない（候補外の言語が話されている場合）
    @Test func returnsNilWhenNoCandidateMatches() {
        let spoken = [
            (locale: "ja-JP", text: "Das ist ein deutscher Satz, der weder japanisch noch englisch ist."),
            (locale: "en-US", text: "Das ist ein deutscher Satz, der weder japanisch noch englisch ist."),
        ]

        #expect(LanguageDecider.decide(spoken) == nil)
    }
}
