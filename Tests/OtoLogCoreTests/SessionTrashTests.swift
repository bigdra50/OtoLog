import Foundation
@testable import OtoLogCore
import Testing

/// セッション削除の対象解決。削除は破壊的操作なので、
/// 保存ルートの外を指しうる相対パスを実行前に弾けることを仕様として固定する。
struct SessionTrashTests {
    // MARK: Internal

    @Test func 日付フォルダ階層の相対パスをルート配下に解決する() {
        let url = SessionTrash.resolveDirectory(root: root, relativePath: "2026-08-03/Claude-会議")

        #expect(url?.path == "/tmp/otolog-save/2026-08-03/Claude-会議")
    }

    @Test func 旧フラット構造の相対パスも解決する() {
        let url = SessionTrash.resolveDirectory(root: root, relativePath: "2026-08-03_1500")

        #expect(url?.path == "/tmp/otolog-save/2026-08-03_1500")
    }

    @Test func 空の相対パスは解決しない() {
        #expect(SessionTrash.resolveDirectory(root: root, relativePath: "") == nil)
    }

    @Test func 絶対パスは解決しない() {
        #expect(SessionTrash.resolveDirectory(root: root, relativePath: "/etc") == nil)
    }

    @Test func 親ディレクトリ参照を含むパスは解決しない() {
        #expect(SessionTrash.resolveDirectory(root: root, relativePath: "../outside") == nil)
        #expect(SessionTrash.resolveDirectory(root: root, relativePath: "2026-08-03/../../outside") == nil)
    }

    @Test func カレントディレクトリ参照を含むパスは解決しない() {
        #expect(SessionTrash.resolveDirectory(root: root, relativePath: "./2026-08-03_1500") == nil)
    }

    @Test func 解決できないパスのゴミ箱移動はエラーにする() {
        #expect(throws: SessionTrashError.invalidSessionPath("../outside")) {
            try SessionTrash.moveToTrash(root: root, relativePath: "../outside")
        }
    }

    // MARK: Private

    private let root = URL(fileURLWithPath: "/tmp/otolog-save")
}
