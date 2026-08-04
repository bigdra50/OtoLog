import MarkdownUI
import SwiftUI

/// ```mermaid のコードブロックを図として描き、失敗したらソースのまま見せる。
///
/// 図が出ないより、書いたものがそのまま読めるほうがましなので、
/// 描画できないときは黙って消さずコードブロックへ戻す。
struct MermaidCodeBlock: View {
    // MARK: Internal

    let source: String

    var body: some View {
        if let failure {
            VStack(alignment: .leading, spacing: 4) {
                Label("図を描画できません: \(failure)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                sourceBlock
            }
        } else {
            MermaidView(source: source, height: $height) { message in
                failure = message
            }
            .frame(height: max(height, 1))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }

    // MARK: Private

    @State private var height: CGFloat = 0
    @State private var failure: String?

    private var sourceBlock: some View {
        Text(source)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}
