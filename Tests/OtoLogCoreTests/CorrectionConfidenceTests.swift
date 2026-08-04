import Foundation
@testable import OtoLogCore
import Testing

/// 補正エントリの信頼度。
/// AI が暫定で貯め、人のチェックで確定させる。未チェックでも使えるが、
/// 「観測され続けて、まだ誰にも否定されていない」ぶんだけ確からしさが上がる。
struct CorrectionConfidenceTests {
    // MARK: Internal

    let now = Date(timeIntervalSince1970: 1_785_297_600)

    @Test func 人が確認したものは最大() {
        let entry = makeEntry(review: .confirmed, count: 1)
        #expect(entry.confidence(asOf: now) == 1.0)
    }

    @Test func 人が否定したものはゼロ() {
        let entry = makeEntry(review: .rejected, count: 99)
        #expect(entry.confidence(asOf: now) == 0)
    }

    /// 未チェックでも使える。初回から補正に効かせるため
    @Test func 未チェックでもゼロにはならない() {
        let entry = makeEntry(review: .unreviewed, count: 1)
        #expect(entry.confidence(asOf: now) > 0)
    }

    @Test func 観測回数が増えると上がる() {
        let once = makeEntry(review: .unreviewed, count: 1)
        let many = makeEntry(review: .unreviewed, count: 16)

        #expect(many.confidence(asOf: now) > once.confidence(asOf: now))
    }

    /// 長く残っているほど上がる。突っ込まれずに生き延びた分を確からしさとみなす
    @Test func 生存期間が長いと上がる() {
        let fresh = makeEntry(review: .unreviewed, count: 2, firstSeenAt: now)
        let aged = makeEntry(review: .unreviewed, count: 2, firstSeenAt: now.addingTimeInterval(-60 * 60 * 24 * 70))

        #expect(aged.confidence(asOf: now) > fresh.confidence(asOf: now))
    }

    /// 未チェックのままでは確認済みに追いつかない。人のチェックが最終的な根拠
    @Test func 未チェックは確認済みを超えない() {
        let veteran = makeEntry(
            review: .unreviewed, count: 9999,
            firstSeenAt: now.addingTimeInterval(-60 * 60 * 24 * 3650)
        )

        #expect(veteran.confidence(asOf: now) < 1.0)
    }

    /// 注入対象は信頼度の高い順。否定されたものは混ざらない
    @Test func プロンプトへは信頼度順で否定分を除いて渡す() {
        let dictionary = CorrectionDictionary(entries: [
            makeEntry(wrong: "却下", review: .rejected, count: 50),
            makeEntry(wrong: "確認済", review: .confirmed, count: 1),
            makeEntry(wrong: "未確認", review: .unreviewed, count: 4),
        ])

        let entries = dictionary.promptEntries(asOf: now)

        #expect(entries.map(\.wrong) == ["確認済", "未確認"])
    }

    /// 旧形式（review も firstSeenAt も無い）の辞書も読める
    @Test func 旧形式のエントリを読み込める() throws {
        let json = """
        {"entries":[{"count":3,"lastSeenAt":"2026-07-29T04:00:00.000Z","right":"閾値","wrong":"敷地"}],"schemaVersion":1}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let string = try dec.singleValueContainer().decode(String.self)
            return JSONLCoder.date(fromISO8601: string) ?? Date()
        }

        let dictionary = try decoder.decode(CorrectionDictionary.self, from: Data(json.utf8))

        let entry = try #require(dictionary.entries.first)
        #expect(entry.review == .unreviewed)
        // 初出が不明な分は最終観測に寄せる（生存期間は 0 から数え直す）
        #expect(entry.firstSeenAt == entry.lastSeenAt)
    }

    // MARK: Private

    private func makeEntry(
        wrong: String = "敷地",
        review: CorrectionReview,
        count: Int,
        firstSeenAt: Date? = nil
    ) -> CorrectionEntry {
        CorrectionEntry(
            wrong: wrong, right: "閾値", count: count,
            firstSeenAt: firstSeenAt ?? now, lastSeenAt: now,
            review: review, reviewedAt: review == .unreviewed ? nil : now
        )
    }
}
