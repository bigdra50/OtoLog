import Foundation
@testable import OtoLogApp
import Testing

/// 記録が実際に残ることを守るテスト。
/// ここが黙って失敗すると、崩れが起きても証拠が残らない状態に戻る。
struct UILogTests {
    @Test func XDG_STATE_HOMEの下のotologへ書く() {
        let url = UILog.resolveFileURL(stateHome: "/tmp/otolog-uilog-test")
        #expect(url.path == "/tmp/otolog-uilog-test/otolog/ui.log")
    }

    @Test func XDG未設定ならホーム配下のlocalstateに落とす() {
        let url = UILog.resolveFileURL(stateHome: nil)
        #expect(url.path.hasSuffix(".local/state/otolog/ui.log"))
    }

    @Test func 空文字のXDGは未設定として扱う() {
        let url = UILog.resolveFileURL(stateHome: "")
        #expect(url.path.hasSuffix(".local/state/otolog/ui.log"))
    }

    @Test func 行は時刻とレベルと本文を含む() {
        let date = Date(timeIntervalSince1970: 1_785_060_000)
        let line = UILog.line(level: .fault, message: "popover shown: clipped=true", at: date)
        #expect(line.contains("[FAULT]"))
        #expect(line.contains("popover shown: clipped=true"))
        #expect(line.hasSuffix("\n"))
        #expect(line.contains("2026-"))
    }

    @Test func ディレクトリが無くても作って追記する() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "otolog-uilog-\(UUID().uuidString)")
        let target = root.appending(path: "nested/ui.log")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(UILog.write(level: .info, message: "1回目", to: target))
        #expect(UILog.write(level: .fault, message: "2回目", to: target))

        let contents = try String(contentsOf: target, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(contents.contains("1回目"))
        #expect(contents.contains("2回目"))
    }

    @Test func 書けない場所では失敗を返し例外を投げない() {
        let unwritable = URL(fileURLWithPath: "/System/otolog-should-not-be-writable/ui.log")
        #expect(!UILog.write(level: .info, message: "書けない", to: unwritable))
    }
}
