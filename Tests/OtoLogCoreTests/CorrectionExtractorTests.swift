import Foundation
@testable import OtoLogCore
import Testing

struct CorrectionExtractorTests {
    typealias Line = TimestampedLogParser.Line

    /// 置換（removed 直後の inserted）だけを辞書候補として抽出する
    @Test func extractsReplacementPairsFromDiff() {
        let pairs = CorrectionExtractor.pairs(
            original: [Line(time: "17:03:42", text: "任天堂の森と美家紋から発表")],
            corrected: [Line(time: "17:03:42", text: "任天堂の森と美山から発表")]
        )
        #expect(pairs == [CorrectionPair(wrong: "家紋", right: "山")])
    }

    /// 純粋な挿入・削除（フィラー除去など）は文脈依存なので辞書化しない
    @Test func ignoresPureInsertionsAndDeletions() {
        let pairs = CorrectionExtractor.pairs(
            original: [Line(time: "17:03:42", text: "えー発表します")],
            corrected: [Line(time: "17:03:42", text: "発表します")]
        )
        #expect(pairs.isEmpty)
    }

    /// ひらがなだけのペア（てにをは修正）は文脈依存なので辞書化しない
    @Test func ignoresHiraganaOnlyPairs() {
        let pairs = CorrectionExtractor.pairs(
            original: [Line(time: "17:03:42", text: "資料は見ました")],
            corrected: [Line(time: "17:03:42", text: "資料を見ました")]
        )
        #expect(pairs.isEmpty)
    }

    /// 長すぎる置換は文の書き換えであり語の修正ではない
    @Test func ignoresLongRewrites() {
        let pairs = CorrectionExtractor.pairs(
            original: [Line(time: "17:03:42", text: "この長い言い回しは全部書き換えられてしまいました")],
            corrected: [Line(time: "17:03:42", text: "まったく別の言い方に変わった結果の文章になっています")]
        )
        #expect(pairs.isEmpty)
    }

    @Test func extractsMultiplePairsAcrossLines() {
        let pairs = CorrectionExtractor.pairs(
            original: [
                Line(time: "17:03:42", text: "美家紋です"),
                Line(time: "17:04:00", text: "ボクセルの荒像を説明"),
            ],
            corrected: [
                Line(time: "17:03:42", text: "美山です"),
                Line(time: "17:04:00", text: "ボクセルの構造を説明"),
            ]
        )
        #expect(pairs.contains(CorrectionPair(wrong: "家紋", right: "山")))
        #expect(pairs.contains(CorrectionPair(wrong: "荒像", right: "構造")))
    }

    /// 置換元が1文字のペアは辞書化しない。
    /// 文脈を選ばず当たってしまい、実辞書では「ご→誤」「ラ→ナ」が最頻出になっていた
    @Test func ignoresSingleCharacterSources() {
        let pairs = CorrectionExtractor.pairs(
            original: [Line(time: "17:03:42", text: "ご認識の可能性があります")],
            corrected: [Line(time: "17:03:42", text: "誤認識の可能性があります")]
        )
        #expect(pairs.isEmpty)
    }

    /// 記号・空白だけの差分も辞書にしない（句読点の揺れは語の修正ではない）
    @Test func ignoresPunctuationOnlyChanges() {
        let pairs = CorrectionExtractor.pairs(
            original: [Line(time: "17:03:42", text: "これは仕様です。次に進みます")],
            corrected: [Line(time: "17:03:42", text: "これは仕様です、次に進みます")]
        )
        #expect(pairs.isEmpty)
    }

    /// 置換元が2文字以上なら残す。実辞書で有用だったのはこの形
    @Test func keepsMultiCharacterSources() {
        let pairs = CorrectionExtractor.pairs(
            original: [Line(time: "17:03:42", text: "敷地を超えると破綻します")],
            corrected: [Line(time: "17:03:42", text: "閾値を超えると破綻します")]
        )
        #expect(pairs == [CorrectionPair(wrong: "敷地", right: "閾値")])
    }

    /// 前後の空白は落として蓄積する（" 10" と "10" が別エントリにならないように）
    @Test func trimsSurroundingWhitespace() {
        let pairs = CorrectionExtractor.pairs(
            original: [Line(time: "17:03:42", text: "残りは 1位ずつ確認します")],
            corrected: [Line(time: "17:03:42", text: "残りは一意ずつ確認します")]
        )
        #expect(pairs.allSatisfy { !$0.wrong.hasPrefix(" ") && !$0.wrong.hasSuffix(" ") })
    }
}
