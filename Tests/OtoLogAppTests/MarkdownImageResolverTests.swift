import Foundation
@testable import OtoLogApp
import Testing

/// 生成物に埋めた画像の参照解決。
/// 図はセッションディレクトリに置く運用なので、相対パスをそこから引けることが要。
struct MarkdownImageResolverTests {
    let base = URL(fileURLWithPath: "/tmp/sessions/2026-07-31/会議", isDirectory: true)

    @Test func 相対パスはセッションディレクトリから解決する() {
        let resolved = MarkdownImageResolver.localURL(for: URL(string: "diagram.png"), baseURL: base)

        #expect(resolved?.path == "/tmp/sessions/2026-07-31/会議/diagram.png")
    }

    @Test func ドット始まりの相対パスも解決する() {
        let resolved = MarkdownImageResolver.localURL(for: URL(string: "./assets/a.png"), baseURL: base)

        #expect(resolved?.path == "/tmp/sessions/2026-07-31/会議/assets/a.png")
    }

    @Test func 親ディレクトリ参照も解決する() {
        let resolved = MarkdownImageResolver.localURL(for: URL(string: "../shared/b.png"), baseURL: base)

        #expect(resolved?.path == "/tmp/sessions/2026-07-31/shared/b.png")
    }

    @Test func fileスキームの絶対パスはそのまま使う() {
        let resolved = MarkdownImageResolver.localURL(
            for: URL(string: "file:///Users/me/x.png"), baseURL: base
        )

        #expect(resolved?.path == "/Users/me/x.png")
    }

    /// リモートはローカル解決の対象外。呼び出し側がネットワーク経路へ回す
    @Test func httpは対象外() {
        #expect(MarkdownImageResolver.localURL(for: URL(string: "https://example.com/x.png"), baseURL: base) == nil)
        #expect(MarkdownImageResolver.localURL(for: nil, baseURL: base) == nil)
    }

    /// 日本語やスペースを含むパスも解ける（セッション名がそのままディレクトリ名になる）
    @Test func 日本語やスペースを含むパスを解ける() {
        let resolved = MarkdownImageResolver.localURL(for: URL(string: "図%20解.png"), baseURL: base)

        #expect(resolved?.path == "/tmp/sessions/2026-07-31/会議/図 解.png")
    }
}
