import Foundation
@testable import OtoLogCore
import Testing

struct TranscriptDiffTests {
    typealias Line = TimestampedLogParser.Line

    /// 時刻で行を突合し、テキストが変わった行だけを返す
    @Test func returnsOnlyChangedLinesMatchedByTime() {
        let original = [
            Line(time: "17:03:42", text: "森と美家紋から発表"),
            Line(time: "17:03:53", text: "変更なしの行"),
        ]
        let corrected = [
            Line(time: "17:03:42", text: "森と美山から発表"),
            Line(time: "17:03:53", text: "変更なしの行"),
        ]
        let entries = TranscriptDiff.changedEntries(original: original, corrected: corrected)
        #expect(entries.count == 1)
        #expect(entries.first?.time == "17:03:42")
        #expect(entries.first?.segments.contains(CharacterDiff.Segment(text: "山", kind: .inserted)) == true)
    }

    /// 補正側にしかない行は全追加、原文側にしか残らない行は全削除として時刻順に出す
    @Test func unmatchedLinesAppearAsPureInsertionOrDeletion() {
        let original = [
            Line(time: "17:03:42", text: "原文のみの行"),
            Line(time: "17:04:00", text: "共通"),
        ]
        let corrected = [
            Line(time: "17:04:00", text: "共通"),
            Line(time: "17:04:10", text: "補正で足された行"),
        ]
        let entries = TranscriptDiff.changedEntries(original: original, corrected: corrected)
        #expect(entries.map(\.time) == ["17:03:42", "17:04:10"])
        #expect(entries[0].segments == [CharacterDiff.Segment(text: "原文のみの行", kind: .removed)])
        #expect(entries[1].segments == [CharacterDiff.Segment(text: "補正で足された行", kind: .inserted)])
    }

    @Test func identicalTranscriptsProduceNoEntries() {
        let lines = [Line(time: "17:03:42", text: "同一")]
        #expect(TranscriptDiff.changedEntries(original: lines, corrected: lines).isEmpty)
    }
}
