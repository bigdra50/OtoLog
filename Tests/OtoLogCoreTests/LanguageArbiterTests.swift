import Foundation
@testable import OtoLogCore
import Testing

/// 並行認識中の裁定。話者の言語が決まるまで確定結果を溜め、決まった時点で勝者の分だけ放出する。
/// 判定を待つ数秒〜十数秒のあいだの発話を捨てないための仕組み。
struct LanguageArbiterTests {
    // MARK: Internal

    let japanese = "本日はボクセルレンダリングの大規模化についてお話しします。ボクツリーは破綻します。"
    let romanized = "Hong jitsuba, bok seudendaringu no daikibokanituite, ohanashimas. Boktuli, bahatanshimas."

    @Test func holdsSegmentsUntilLanguageIsDecided() {
        var sut = LanguageArbiter(candidates: ["en-US", "ja-JP"])

        // 判定に足りない短い断片では何も出さない
        let emitted = sut.accept(segment(text: "本日は", locale: "ja-JP"))

        #expect(emitted.isEmpty)
        #expect(sut.decidedLocale == nil)
    }

    /// 決まった瞬間に、それまで溜めた勝者の分が順番どおりまとめて出る
    @Test func flushesWinnerBacklogOnDecision() {
        var sut = LanguageArbiter(candidates: ["en-US", "ja-JP"])
        _ = sut.accept(segment(text: "本日は", locale: "ja-JP"))
        _ = sut.accept(segment(text: "Hong jitsuba", locale: "en-US"))

        let emitted = sut.accept(segment(text: japanese, locale: "ja-JP"))

        #expect(sut.decidedLocale == "ja-JP")
        #expect(emitted.map(\.text) == ["本日は", japanese])
    }

    /// 決定後は勝者だけが通り、負けた認識器の結果は捨てる
    @Test func passesOnlyWinnerAfterDecision() {
        var sut = LanguageArbiter(candidates: ["en-US", "ja-JP"])
        _ = sut.accept(segment(text: japanese, locale: "ja-JP"))
        #expect(sut.decidedLocale == "ja-JP")

        #expect(sut.accept(segment(text: "つづき", locale: "ja-JP")).map(\.text) == ["つづき"])
        #expect(sut.accept(segment(text: romanized, locale: "en-US")).isEmpty)
    }

    /// 決まらないまま終わったら、候補の先頭（利用者が指定した既定）で確定させる。
    /// 判定できなかったことを理由に記録を捨てない
    @Test func fallsBackToFirstCandidateOnFlush() {
        var sut = LanguageArbiter(candidates: ["ja-JP", "en-US"])
        _ = sut.accept(segment(text: "みじかい", locale: "ja-JP"))
        _ = sut.accept(segment(text: "short", locale: "en-US"))

        let flushed = sut.flush()

        #expect(sut.decidedLocale == "ja-JP")
        #expect(flushed.map(\.text) == ["みじかい"])
    }

    /// 決定後の flush は何も出さない（放出済みのため）
    @Test func flushAfterDecisionEmitsNothing() {
        var sut = LanguageArbiter(candidates: ["en-US", "ja-JP"])
        _ = sut.accept(segment(text: japanese, locale: "ja-JP"))

        #expect(sut.flush().isEmpty)
    }

    /// volatile も判定材料になる。確定を待たずに決まるほうが字幕が早く出る
    @Test func decidesFromVolatileText() {
        var sut = LanguageArbiter(candidates: ["en-US", "ja-JP"])

        _ = sut.acceptVolatile(text: japanese, locale: "ja-JP")

        #expect(sut.decidedLocale == "ja-JP")
    }

    /// 未決定のあいだのライブ表示は、最も長い結果を出している認識器のものを使う
    @Test func showsLongestVolatileWhileUndecided() {
        var sut = LanguageArbiter(candidates: ["en-US", "ja-JP"])

        #expect(sut.acceptVolatile(text: "本日", locale: "ja-JP") == "本日")
        #expect(sut.acceptVolatile(text: "Hong ji", locale: "en-US") == "Hong ji")
        // 短いほうが後から来ても、表示は長いほうを保つ
        #expect(sut.acceptVolatile(text: "本日", locale: "ja-JP") == "Hong ji")
    }

    /// 決定後の volatile は勝者のものだけを通す
    @Test func showsOnlyWinnerVolatileAfterDecision() {
        var sut = LanguageArbiter(candidates: ["en-US", "ja-JP"])
        _ = sut.accept(segment(text: japanese, locale: "ja-JP"))

        #expect(sut.acceptVolatile(text: "つづき", locale: "ja-JP") == "つづき")
        #expect(sut.acceptVolatile(text: "tsuzuki", locale: "en-US") == nil)
    }

    /// 候補が1つなら並行認識をしないので、最初から決定済みとして素通しする
    @Test func passesThroughWhenSingleCandidate() {
        var sut = LanguageArbiter(candidates: ["ja-JP"])

        #expect(sut.decidedLocale == "ja-JP")
        #expect(sut.accept(segment(text: "みじかい", locale: "ja-JP")).map(\.text) == ["みじかい"])
        #expect(sut.acceptVolatile(text: "み", locale: "ja-JP") == "み")
    }

    // MARK: Private

    private func segment(text: String, locale: String) -> TranscriptSegment {
        TranscriptSegment(
            text: text,
            audioStart: nil,
            audioEnd: nil,
            finalizedAt: Date(timeIntervalSince1970: 1_785_297_600),
            locale: locale,
            source: .system,
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sessionStartedAt: Date(timeIntervalSince1970: 1_785_297_600)
        )
    }
}
