import AppKit
import MarkdownUI
@testable import OtoLogApp
import SwiftUI
import Testing

/// レンダリング結果を目で確かめるための一時的な検証。
/// OTOLOG_RENDER_PROBE=1 のときだけ動き、PNG を書き出す。
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OTOLOG_RENDER_PROBE"] == "1")) struct MarkdownRenderProbe {
    // MARK: Internal

    @Test func 太字とmermaidと画像の描画を書き出す() throws {
        let sample = """
        # 見出し1

        通常のテキストと **太字のテキスト** の比較。
        英語だと normal と **bold** の違い。

        **文脈**：生成物で実際に使われている書き方。

        ## 見出し2

        ```mermaid
        graph TD
          A[開始] --> B[処理]
        ```

        ![ローカル画像](./sample.png)

        | 列1 | 列2 |
        | --- | --- |
        | a | b |
        """

        try write(sample, theme: .otolog, to: "render-otolog.png")

        // 画像は同じディレクトリに実体を置いて確かめる
        let dir = URL(fileURLWithPath: NSString(string: "~/Downloads").expandingTildeInPath)
        let png = dir.appendingPathComponent("sample.png")
        try makeSquare().write(to: png)
        let images = """
        単独ブロック（相対）:

        ![相対](sample.png)

        行内（相対）: ![相対](sample.png) の続き。

        単独ブロック（file URL）:

        ![file](\(png.absoluteString))

        存在しない: ![欠番](missing.png)
        """
        try write(images, theme: .otolog, to: "render-images.png", baseURL: dir)

        let mermaid = """
        ```mermaid
        graph LR
          A[記録] --> B[認識]
          B --> C[翻訳]
          C --> D[保存]
        ```

        ```swift
        let x = 1
        ```

        ```mermaid
        これは壊れた図
        ```
        """
        try write(mermaid, theme: .otolog, to: "render-mermaid.png")
    }

    // MARK: Private

    /// 埋め込み確認用の 80x40 の単色 PNG
    private func makeSquare() -> Data {
        let image = NSImage(size: NSSize(width: 80, height: 40))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 80, height: 40).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else { return Data() }
        return data
    }

    private func write(_ markdown: String, theme: Theme, to name: String, baseURL: URL? = nil) throws {
        let view = Markdown(markdown, imageBaseURL: baseURL)
            .markdownTheme(theme)
            .markdownImageProvider(SessionImageProvider(
                baseURL: baseURL ?? URL(fileURLWithPath: NSTemporaryDirectory())
            ))
            .markdownInlineImageProvider(SessionInlineImageProvider(
                baseURL: baseURL ?? URL(fileURLWithPath: NSTemporaryDirectory())
            ))
            .frame(width: 520, alignment: .leading)
            .padding(16)
            .background(Color.white)
        let hosting = NSHostingController(rootView: view)
        let size = hosting.view.fittingSize
        hosting.view.frame = CGRect(origin: .zero, size: size)
        hosting.view.layoutSubtreeIfNeeded()
        // 画像は非同期で読み込まれる。描画前に待たないと「出ていない」ように見える
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        hosting.view.layoutSubtreeIfNeeded()

        guard let rep = hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds) else { return }
        hosting.view.cacheDisplay(in: hosting.view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let out = URL(fileURLWithPath: NSString(string: "~/Downloads").expandingTildeInPath)
            .appendingPathComponent(name)
        try data.write(to: out)
        print("wrote \(out.path) (\(Int(size.width))x\(Int(size.height)))")
    }
}
