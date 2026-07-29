import Foundation
@testable import OtoLogCore
import Testing

struct CharacterDiffTests {
    @Test func equalStringsProduceSingleEqualSegment() {
        let segments = CharacterDiff.diff(old: "同じ文", new: "同じ文")
        #expect(segments == [CharacterDiff.Segment(text: "同じ文", kind: .equal)])
    }

    /// 音声認識の誤変換修正で最も多い「中間の置換」を、前後の equal を保って抽出する
    @Test func replacementInMiddleKeepsSurroundingEqual() {
        let segments = CharacterDiff.diff(old: "森と美家紋から発表", new: "森と美山から発表")
        #expect(segments == [
            CharacterDiff.Segment(text: "森と美", kind: .equal),
            CharacterDiff.Segment(text: "家紋", kind: .removed),
            CharacterDiff.Segment(text: "山", kind: .inserted),
            CharacterDiff.Segment(text: "から発表", kind: .equal),
        ])
    }

    @Test func pureInsertionAndDeletion() {
        #expect(CharacterDiff.diff(old: "発表", new: "発表します") == [
            CharacterDiff.Segment(text: "発表", kind: .equal),
            CharacterDiff.Segment(text: "します", kind: .inserted),
        ])
        #expect(CharacterDiff.diff(old: "えー発表", new: "発表") == [
            CharacterDiff.Segment(text: "えー", kind: .removed),
            CharacterDiff.Segment(text: "発表", kind: .equal),
        ])
    }

    /// 極端に長い行は LCS を諦めて全置換にする（表示は成立し、計算が爆発しない）
    @Test func fallsBackToFullReplacementForVeryLongLines() {
        let old = String(repeating: "あ", count: 1500)
        let new = String(repeating: "い", count: 1500)
        let segments = CharacterDiff.diff(old: old, new: new)
        #expect(segments == [
            CharacterDiff.Segment(text: old, kind: .removed),
            CharacterDiff.Segment(text: new, kind: .inserted),
        ])
    }
}
