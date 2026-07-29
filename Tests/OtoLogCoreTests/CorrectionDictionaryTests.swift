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

    /// プロンプト注入は複数回観測されたペアだけ（1回きりは文脈依存の可能性）
    @Test func promptEntriesRequireMinimumCountAndOrderByFrequency() {
        var dictionary = CorrectionDictionary()
        let now = Date(timeIntervalSince1970: 1_785_297_600)
        dictionary.entries = [
            CorrectionEntry(wrong: "一回だけ", right: "一度だけ", count: 1, lastSeenAt: now),
            CorrectionEntry(wrong: "家紋", right: "山", count: 3, lastSeenAt: now),
            CorrectionEntry(wrong: "解", right: "構", count: 2, lastSeenAt: now),
        ]
        let entries = dictionary.promptEntries(minimumCount: 2, limit: 10)
        #expect(entries.map(\.wrong) == ["家紋", "解"])
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

    // MARK: Private

    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }
}
