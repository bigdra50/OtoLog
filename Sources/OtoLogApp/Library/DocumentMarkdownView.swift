import MarkdownUI
import OtoLogCore
import SwiftUI

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
        .onAppear {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
                content = "ファイルを読み込めませんでした: \(url.lastPathComponent)"
                return
            }
            content = PostProcessRunner.stripProvenanceHeader(raw)
            timestampedLines = TimestampedLogParser.parse(content)
        }
    }

    // MARK: Private

    @State private var content = ""
    @State private var timestampedLines: [TimestampedLogParser.Line]?
}
