import Foundation
@testable import OtoLogCore
import Testing

/// 現況メモ。型にはめられないニュアンスを Claude の裁量で書き足していく器。
/// 構造化した用語集・アクションとは別に持つ（更新の頻度も寿命も違う）。
struct SituationStoreTests {
    // MARK: Internal

    @Test func 未作成なら空() throws {
        try withTempDir { dir in
            #expect(SituationStore(fileURL: dir.appendingPathComponent("none.md")).load().isEmpty)
        }
    }

    @Test func 書いて読み直せる() throws {
        try withTempDir { dir in
            let store = SituationStore(fileURL: dir.appendingPathComponent("context.md"))

            try store.save("## リクルート案件\n見積もり中。")

            #expect(store.load().contains("見積もり中。"))
        }
    }

    /// 前の版は残す。裁量に任せる以上、丸ごと書き換えられて困ることがある
    @Test func 上書き前の版を退避する() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("context.md")
            let store = SituationStore(fileURL: url)
            try store.save("最初の内容")

            try store.save("次の内容")

            #expect(store.load() == "次の内容")
            let backup = try String(contentsOf: store.previousURL, encoding: .utf8)
            #expect(backup == "最初の内容")
        }
    }

    /// 空の結果で既存を吹き飛ばさない。生成が失敗したときに全部消えるのが最悪
    @Test func 空文字では上書きしない() throws {
        try withTempDir { dir in
            let store = SituationStore(fileURL: dir.appendingPathComponent("context.md"))
            try store.save("残すべき内容")

            #expect(throws: (any Error).self) { try store.save("   \n  ") }
            #expect(store.load() == "残すべき内容")
        }
    }

    // MARK: Private

    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogSit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }
}
