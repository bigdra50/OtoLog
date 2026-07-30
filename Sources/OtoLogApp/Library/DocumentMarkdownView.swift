import MarkdownUI
import OtoLogCore
import SwiftUI

// MARK: - DocumentContent

/// 生成物 md の読み込み結果（由来ヘッダ除去済み本文と、行ログなら構造化行）。
struct DocumentContent: Equatable {
    let content: String
    let timestampedLines: [TimestampedLogParser.Line]?
}

// MARK: - DocumentMarkdownView

/// 生成物 md の表示。由来ヘッダ（HTML コメント）は表示しない。
/// 本文が「[HH:mm:ss] 本文」の行ログ（correct 等）のときは、Markdown レンダリングだと
/// 改行が段落結合されて読めなくなるため、文字起こしと同じ時刻付きリストで表示する。
struct DocumentMarkdownView: View {
    // MARK: Internal

    let url: URL

    var body: some View {
        ScrollView {
            if let timestampedLines {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(timestampedLines.enumerated()), id: \.offset) { _, line in
                        TimestampedRow(time: line.time, text: line.text)
                    }
                }
                .padding(16)
                .textSelection(.enabled)
            } else {
                Markdown(content)
                    .markdownTheme(.gitHub)
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            let url = url
            let loaded = await OffMainIO.read { Self.load(url: url) }
            content = loaded.content
            timestampedLines = loaded.timestampedLines
        }
    }

    /// 保存先を読むので MainActor では呼ばない
    nonisolated static func load(url: URL) -> DocumentContent {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return DocumentContent(
                content: "ファイルを読み込めませんでした: \(url.lastPathComponent)",
                timestampedLines: nil
            )
        }
        let content = PostProcessRunner.stripProvenanceHeader(raw)
        return DocumentContent(content: content, timestampedLines: TimestampedLogParser.parse(content))
    }

    // MARK: Private

    @State private var content = ""
    @State private var timestampedLines: [TimestampedLogParser.Line]?
}
