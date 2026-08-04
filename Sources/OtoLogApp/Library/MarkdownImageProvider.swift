import MarkdownUI
import SwiftUI

// MARK: - MarkdownImageResolver

/// Markdown の画像参照をローカルファイルへ解決する。
/// 図はセッションディレクトリへ置く運用なので、相対パスはそこを基準にする。
enum MarkdownImageResolver {
    /// ローカルとして扱えないもの（http(s) など）は nil
    static func localURL(for url: URL?, baseURL: URL) -> URL? {
        guard let url else { return nil }
        if let scheme = url.scheme {
            guard scheme == "file" else { return nil }
            return url.standardizedFileURL
        }
        // パーセントエンコードを解いてから連結する（日本語やスペースを含む名前のため）
        let path = url.path.removingPercentEncoding ?? url.path
        return URL(fileURLWithPath: path, relativeTo: baseURL).standardizedFileURL
    }
}

// MARK: - SessionInlineImageProvider

/// 文中に置かれた画像（`テキスト ![図](a.png) テキスト`）用。
/// MarkdownUI は行内の画像を単独ブロックとは別経路で扱うため、両方を差し替えないと片方が出ない。
struct SessionInlineImageProvider: InlineImageProvider {
    let baseURL: URL

    func image(with url: URL, label _: String) async throws -> Image {
        guard let local = MarkdownImageResolver.localURL(for: url, baseURL: baseURL),
              let image = NSImage(contentsOf: local)
        else { throw CocoaError(.fileNoSuchFile) }
        return Image(nsImage: image)
    }
}

// MARK: - SessionImageProvider

/// 生成物と同じディレクトリに置いた画像を表示する。
///
/// 既定の provider はネットワーク前提で、相対パスもローカルファイルも解決できないうえ、
/// 失敗しても 0x0 の透明ビューを返すため「行が消えたように見える」。
/// 読めなかったことが分かる表示にしておく。
struct SessionImageProvider: ImageProvider {
    let baseURL: URL

    func makeImage(url: URL?) -> some View {
        if let local = MarkdownImageResolver.localURL(for: url, baseURL: baseURL),
           let image = NSImage(contentsOf: local) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                // 原寸より拡大するとぼやけるので上限を実サイズに合わせる
                .frame(maxWidth: image.size.width, maxHeight: image.size.height)
        } else {
            Label(
                url.map { "画像を読み込めません: \($0.lastPathComponent)" } ?? "画像の参照が空です",
                systemImage: "photo.badge.exclamationmark"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
