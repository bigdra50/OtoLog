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
                Line(time: "17:04:00", text: "ボクセルの解造を説明"),
            ],
            corrected: [
                Line(time: "17:03:42", text: "美山です"),
                Line(time: "17:04:00", text: "ボクセルの構造を説明"),
            ]
        )
        #expect(pairs.contains(CorrectionPair(wrong: "家紋", right: "山")))
        #expect(pairs.contains(CorrectionPair(wrong: "解", right: "構")))
    }
}
