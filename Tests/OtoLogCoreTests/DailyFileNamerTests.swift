import Foundation
@testable import OtoLogCore
import Testing

struct DailyFileNamerTests {
    let jst = DailyFileNamer(timeZone: TimeZone(identifier: "Asia/Tokyo")!)

    @Test func computesStemInInjectedTimeZone() {
        // 2026-07-29T04:00:00Z = 13:00 JST
        #expect(jst.stem(for: Date(timeIntervalSince1970: 1_785_297_600)) == "2026-07-29")
    }

    @Test func rollsOverAtLocalMidnight() {
        // 2026-07-29T14:59:59Z = 23:59:59 JST、+1秒で翌日
        #expect(jst.stem(for: Date(timeIntervalSince1970: 1_785_337_199)) == "2026-07-29")
        #expect(jst.stem(for: Date(timeIntervalSince1970: 1_785_337_200)) == "2026-07-30")
    }

    @Test func differsAcrossTimeZones() throws {
        let utc = try DailyFileNamer(timeZone: #require(TimeZone(identifier: "UTC")))
        // 2026-07-29T20:00:00Z は JST では翌30日 05:00
        let date = Date(timeIntervalSince1970: 1_785_355_200)
        #expect(utc.stem(for: date) == "2026-07-29")
        #expect(jst.stem(for: date) == "2026-07-30")
    }
}
