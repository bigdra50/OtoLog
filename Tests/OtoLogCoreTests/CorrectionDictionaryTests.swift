import Foundation
@testable import OtoLogCore
import Testing

struct CorrectionDictionaryTests {
    // MARK: Internal

    @Test func recordAccumulatesCountsAndPersists() throws {
        try withTempDir { dir in
            let store = CorrectionDictionaryStore(fileURL: dir.appendingPathComponent("corrections.json"))
            let now = Date(timeIntervalSince1970: 1_785_297_600)

            _ = try store.record([CorrectionPair(wrong: "家紋", right: "山")], now: now)
            let dictionary = try store.record([CorrectionPair(wrong: "家紋", right: "山")], now: now)

            #expect(dictionary.entries.count == 1)
            #expect(dictionary.entries.first?.count == 2)
            // 別インスタンスで読み直しても永続化されている
            let reloaded = CorrectionDictionaryStore(fileURL: dir.appendingPathComponent("corrections.json")).load()
            #expect(reloaded == dictionary)
        }
    }

    /// 逆向きのペアが観測されたら両方無効化する（誤学習の混入監査）
    @Test func recordRemovesContradictoryPairs() throws {
        try withTempDir { dir in
            let store = CorrectionDictionaryStore(fileURL: dir.appendingPathComponent("corrections.json"))
            let now = Date(timeIntervalSince1970: 1_785_297_600)

            _ = try store.record([CorrectionPair(wrong: "構造", right: "校蔵")], now: now)
            let dictionary = try store.record([CorrectionPair(wrong: "校蔵", right: "構造")], now: now)

            #expect(dictionary.entries.isEmpty)
        }
    }

    /// 上限を超えたら古いエントリから捨てる
    @Test func recordPrunesOldestEntriesBeyondLimit() throws {
        try withTempDir { dir in
            let store = CorrectionDictionaryStore(
                fileURL: dir.appendingPathComponent("corrections.json"), maxEntries: 2
            )
            let base = Date(timeIntervalSince1970: 1_785_297_600)

            _ = try store.record([CorrectionPair(wrong: "あ誤1", right: "正1")], now: base)
            _ = try store.record([CorrectionPair(wrong: "い誤2", right: "正2")], now: base.addingTimeInterval(60))
            let dictionary = try store.record(
                [CorrectionPair(wrong: "う誤3", right: "正3")], now: base.addingTimeInterval(120)
            )

            #expect(dictionary.entries.count == 2)
            #expect(!dictionary.entries.contains { $0.wrong == "あ誤1" })
        }
    }

    /// プロンプト注入は信頼度が閾値を超えたものだけ（1回きりの観測は届かない）
    @Test func promptEntriesFilterByConfidenceAndOrderByIt() {
        var dictionary = CorrectionDictionary()
        let now = Date(timeIntervalSince1970: 1_785_297_600)
        dictionary.entries = [
            CorrectionEntry(wrong: "一回だけ", right: "一度だけ", count: 1, firstSeenAt: now, lastSeenAt: now),
            CorrectionEntry(wrong: "家紋", right: "山", count: 3, firstSeenAt: now, lastSeenAt: now),
            CorrectionEntry(wrong: "荒像", right: "構造", count: 2, firstSeenAt: now, lastSeenAt: now),
        ]

        let entries = dictionary.promptEntries(limit: 10, asOf: now)

        #expect(entries.map(\.wrong) == ["家紋", "荒像"])
    }

    @Test func loadReturnsEmptyDictionaryForMissingOrBrokenFile() throws {
        try withTempDir { dir in
            let missing = CorrectionDictionaryStore(fileURL: dir.appendingPathComponent("none.json"))
            #expect(missing.load() == CorrectionDictionary())

            let brokenURL = dir.appendingPathComponent("broken.json")
            try "{broken".write(to: brokenURL, atomically: true, encoding: .utf8)
            #expect(CorrectionDictionaryStore(fileURL: brokenURL).load() == CorrectionDictionary())
        }
    }

    /// 基準を厳しくする前に貯まったエントリは読み込み時に落とす。
    /// 実辞書では「ご→誤」が 39 回で最頻出になり、有用なエントリを押しのけていた
    @Test func loadDropsEntriesThatNoLongerQualify() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("corrections.json")
            let store = CorrectionDictionaryStore(fileURL: url)
            let now = Date(timeIntervalSince1970: 1_785_297_600)
            try store.save(CorrectionDictionary(entries: [
                CorrectionEntry(wrong: "ご", right: "誤", count: 39, firstSeenAt: now, lastSeenAt: now),
                CorrectionEntry(wrong: "。", right: "、", count: 8, firstSeenAt: now, lastSeenAt: now),
                CorrectionEntry(wrong: "敷地", right: "閾値", count: 12, firstSeenAt: now, lastSeenAt: now),
            ]))

            let loaded = store.load()

            #expect(loaded.entries.map(\.wrong) == ["敷地"])
        }
    }

    /// 人のチェック結果は書き戻して永続化する
    @Test func reviewMarksEntryAndPersists() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("corrections.json")
            let store = CorrectionDictionaryStore(fileURL: url)
            let now = Date(timeIntervalSince1970: 1_785_297_600)
            _ = try store.record([CorrectionPair(wrong: "敷地", right: "閾値")], now: now)

            _ = try store.review(wrong: "敷地", right: "閾値", as: .confirmed, now: now)

            let entry = try #require(store.load().entries.first)
            #expect(entry.review == .confirmed)
            #expect(entry.reviewedAt == now)
            #expect(entry.confidence(asOf: now) == 1.0)
        }
    }

    /// 却下したエントリは残す。消すと再学習で未チェックとして戻ってきてしまう
    @Test func rejectedEntriesSurviveAndStayOutOfPrompts() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("corrections.json")
            let store = CorrectionDictionaryStore(fileURL: url)
            let now = Date(timeIntervalSince1970: 1_785_297_600)
            _ = try store.record([CorrectionPair(wrong: "鎌倉", right: "かまくら")], now: now)
            _ = try store.review(wrong: "鎌倉", right: "かまくら", as: .rejected, now: now)

            // 同じ誤りをまた観測しても、却下の判断は上書きされない
            let dictionary = try store.record([CorrectionPair(wrong: "鎌倉", right: "かまくら")], now: now)

            #expect(dictionary.entries.first?.review == .rejected)
            #expect(dictionary.promptEntries(asOf: now).isEmpty)
        }
    }

    /// 上限を超えても人が判断したものは残す。自動で貯まった分から捨てる
    @Test func prunesUnreviewedEntriesBeforeReviewedOnes() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("corrections.json")
            let store = CorrectionDictionaryStore(fileURL: url, maxEntries: 2)
            let base = Date(timeIntervalSince1970: 1_785_297_600)
            _ = try store.record([CorrectionPair(wrong: "あ誤1", right: "正1")], now: base)
            _ = try store.review(wrong: "あ誤1", right: "正1", as: .confirmed, now: base)
            _ = try store.record([CorrectionPair(wrong: "い誤2", right: "正2")], now: base.addingTimeInterval(60))

            let dictionary = try store.record(
                [CorrectionPair(wrong: "う誤3", right: "正3")], now: base.addingTimeInterval(120)
            )

            #expect(dictionary.entries.contains { $0.wrong == "あ誤1" })
            #expect(dictionary.entries.count == 2)
        }
    }

    // MARK: Private

    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }
}
