import Foundation
@testable import OtoLogApp
import Testing

/// 保存先 FS アクセスの退避実行がメインスレッドを塞がない契約を守る。
@MainActor struct OffMainIOTests {
    @Test func readはメインスレッドの外で実行される() async {
        let ranOnMain = await OffMainIO.read { Thread.isMainThread }
        #expect(!ranOnMain)
    }

    @Test func readは結果をそのまま返す() async {
        let value = await OffMainIO.read { 42 }
        #expect(value == 42)
    }
}
