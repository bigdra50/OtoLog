import Foundation
@testable import OtoLogCore
import Testing

struct MarkdownFormatterTests {
    let formatter = MarkdownFormatter(timeZone: TimeZone(identifier: "Asia/Tokyo")!)

    /// 1_785_297_600 = 2026-07-29T04:00:00Z = 13:00:00 JST
    let finalizedAt = Date(timeIntervalSince1970: 1_785_297_600)

    func makeSegment(text: String, source: AudioSourceKind = .system) -> TranscriptSegment {
        TranscriptSegment(
            text: text,
            audioStart: nil,
            audioEnd: nil,
            finalizedAt: finalizedAt,
            locale: "ja-JP",
            source: source,
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sessionStartedAt: finalizedAt
        )
    }

    @Test func rendersHeaderForStem() {
        #expect(formatter.header(forStem: "2026-07-29") == "# 2026-07-29\n\n")
    }

    @Test func rendersTimestampedLine() {
        let line = formatter.line(for: makeSegment(text: "こんにちは"))
        #expect(line == "- **13:00:00** こんにちは\n")
    }

    @Test func squashesNewlinesAndTrimsWhitespace() {
        let line = formatter.line(for: makeSegment(text: "  1行目\n2行目  "))
        #expect(line == "- **13:00:00** 1行目 2行目\n")
    }

    @Test func returnsNilForWhitespaceOnlyText() {
        let line = formatter.line(for: makeSegment(text: " \n\t "))
        #expect(line == nil)
    }

    /// 訳は原文の子行として併記する。原文を正本として残したまま訳を読めるようにするため
    @Test func rendersTranslationAsChildLine() {
        var segment = makeSegment(text: "こんにちは")
        segment.translation = "Hello"

        let line = formatter.line(for: segment)

        #expect(line == "- **13:00:00** こんにちは\n  - Hello\n")
    }

    @Test func squashesNewlinesInTranslation() {
        var segment = makeSegment(text: "こんにちは")
        segment.translation = "  Hello\nworld  "

        let line = formatter.line(for: segment)

        #expect(line == "- **13:00:00** こんにちは\n  - Hello world\n")
    }

    /// 訳が空白だけなら子行を足さない（原文だけの行に落とす）
    @Test func skipsChildLineForWhitespaceOnlyTranslation() {
        var segment = makeSegment(text: "こんにちは")
        segment.translation = "   "

        let line = formatter.line(for: segment)

        #expect(line == "- **13:00:00** こんにちは\n")
    }

    /// マイク由来（＝話者本人）の発言は「自分:」で区別する。
    /// システム音声側は従来表記のまま（会議以外の記録を話者ラベルで汚さない）
    @Test func prefixesMicrophoneSegmentWithSpeakerLabel() {
        let line = formatter.line(for: makeSegment(text: "承知しました", source: .microphone))
        #expect(line == "- **13:00:00** 自分: 承知しました\n")
    }

    @Test func keepsTranslationChildLineForMicrophoneSegment() {
        var segment = makeSegment(text: "承知しました", source: .microphone)
        segment.translation = "Understood"

        let line = formatter.line(for: segment)

        #expect(line == "- **13:00:00** 自分: 承知しました\n  - Understood\n")
    }
}
