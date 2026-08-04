import MarkdownUI
import SwiftUI

extension Theme {
    /// GitHub テーマの強調だけを差し替えたもの。
    ///
    /// 既定の `.semibold` は日本語フォントに該当ウェイトが無く、
    /// 「**太字**」が地の文と同じ太さで出てしまう（英字だけ太くなる）。
    ///
    /// Theme は Sendable ではないため、生成のたびに作る（軽い値の組み立てのみ）
    @MainActor static var otolog: Theme {
        Theme.gitHub
            .strong {
                FontWeight(.bold)
            }
            // mermaid だけ図に差し替える。他の言語は GitHub テーマの体裁のまま
            .codeBlock { configuration in
                if configuration.language == "mermaid" {
                    MermaidCodeBlock(source: configuration.content)
                } else {
                    ScrollView(.horizontal) {
                        configuration.label
                            .fixedSize(horizontal: false, vertical: true)
                            .relativeLineSpacing(.em(0.225))
                            .markdownTextStyle {
                                FontFamilyVariant(.monospaced)
                                FontSize(.em(0.85))
                            }
                            .padding(16)
                    }
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .markdownMargin(top: 0, bottom: 16)
                }
            }
    }
}
