import Foundation
@testable import OtoLogCore
import Testing

struct SessionDirectoryNamerTests {
    let jst = TimeZone(identifier: "Asia/Tokyo")!

    /// 1785297600 = 2026-07-29 13:00 JST
    @Test func baseNameUsesInjectedTimeZone() {
        let namer = SessionDirectoryNamer(timeZone: jst)
        #expect(namer.baseName(for: Date(timeIntervalSince1970: 1_785_297_600)) == "2026-07-29_1300")
    }

    @Test func directoryNameAppendsSanitizedTitle() {
        let namer = SessionDirectoryNamer(timeZone: jst)
        let date = Date(timeIntervalSince1970: 1_785_297_600)
        #expect(namer.directoryName(startedAt: date, title: "CEDEC ボクセル技術") == "2026-07-29_1300_CEDEC-ボクセル技術")
        #expect(namer.directoryName(startedAt: date, title: nil) == "2026-07-29_1300")
    }

    @Test func sanitizeReplacesUnsafeCharactersWithHyphen() {
        #expect(SessionDirectoryNamer.sanitizeTitle("a/b\\c:d*e?f\"g<h>i|j") == "a-b-c-d-e-f-g-h-i-j")
        #expect(SessionDirectoryNamer.sanitizeTitle("空白 と　全角空白") == "空白-と-全角空白")
    }

    @Test func sanitizeCollapsesAndTrimsHyphens() {
        #expect(SessionDirectoryNamer.sanitizeTitle("  --a - b--  ") == "a-b")
    }

    @Test func sanitizeEnforcesMaxLength() {
        let long = String(repeating: "あ", count: 50)
        #expect(SessionDirectoryNamer.sanitizeTitle(long)?.count == 40)
    }

    /// ファイル名にできない空タイトルは nil（呼び出し側はタイトルなし扱い）
    @Test func sanitizeReturnsNilForEffectivelyEmptyTitle() {
        #expect(SessionDirectoryNamer.sanitizeTitle("") == nil)
        #expect(SessionDirectoryNamer.sanitizeTitle("  // :: ") == nil)
    }

    /// 日付フォルダ階層の相対パス: <yyyy-MM-dd>/<タイトル or HHmm>
    @Test func relativePathGroupsByDateWithTitleOrTime() {
        let namer = SessionDirectoryNamer(timeZone: jst)
        let date = Date(timeIntervalSince1970: 1_785_297_600) // 2026-07-29 13:00 JST
        #expect(namer.relativePath(startedAt: date, title: "ボクセル技術講演") == "2026-07-29/ボクセル技術講演")
        #expect(namer.relativePath(startedAt: date, title: nil) == "2026-07-29/1300")
    }

    /// 新旧両形式の相対パスから開始時刻を復元できる（meta 破損時のフォールバック）
    @Test func parsesStartedAtFromOldAndNewRelativePaths() {
        let namer = SessionDirectoryNamer(timeZone: jst)
        let expected = Date(timeIntervalSince1970: 1_785_297_600)
        // 新構造: 日付/時刻
        #expect(namer.parseStartedAt(fromRelativePath: "2026-07-29/1300") == expected)
        #expect(namer.parseStartedAt(fromRelativePath: "2026-07-29/1300-2") == expected)
        // 新構造: 日付/タイトル → 日付のみ復元（0時扱い）
        #expect(namer.parseStartedAt(fromRelativePath: "2026-07-29/タイトルのみ")
            == Date(timeIntervalSince1970: 1_785_250_800))
        // 旧フラット構造
        #expect(namer.parseStartedAt(fromRelativePath: "2026-07-29_1300_古い形式") == expected)
        #expect(namer.parseStartedAt(fromRelativePath: "無関係") == nil)
    }
}
