import Foundation
@testable import OtoLogCore
import Testing

struct TimestampedLogParserTests {
    /// correct 等の出力（[HH:mm:ss] 本文 の行ログ）を構造化する
    @Test func parsesTimestampedLines() {
        let contents = """
        [17:03:42] 皆さんこんにちは。
        [17:03:53] 本セッションは撮影OKです。
        """
        let lines = TimestampedLogParser.parse(contents)
        #expect(lines?.count == 2)
        #expect(lines?.first?.time == "17:03:42")
        #expect(lines?.first?.text == "皆さんこんにちは。")
    }

    @Test func skipsEmptyLinesBetweenEntries() {
        let contents = "[17:03:42] 一行目\n\n[17:03:53] 二行目\n"
        let lines = TimestampedLogParser.parse(contents)
        #expect(lines?.map(\.text) == ["一行目", "二行目"])
    }

    /// 形式外の行が混ざる文書は「時刻付きログではない」ので nil（通常の Markdown として表示する）
    @Test func returnsNilForMixedOrMarkdownContent() {
        #expect(TimestampedLogParser.parse("[17:03:42] 一行目\n見出しのない補足文") == nil)
        #expect(TimestampedLogParser.parse("# 議事録\n\n- 決定: A") == nil)
        #expect(TimestampedLogParser.parse("") == nil)
        #expect(TimestampedLogParser.parse("   \n  ") == nil)
    }
}
