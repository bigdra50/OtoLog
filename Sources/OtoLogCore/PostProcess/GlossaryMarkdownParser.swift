import Foundation

/// 構造化出力より前に生成された用語集（Markdown だけが残っているもの）から用語を拾う。
///
/// 用語集は「## 用語 + 本文」のこともあれば「## 分類 + ### 用語」のこともあり、
/// 書かせた側で体裁を決められない。この曖昧さこそ構造化出力へ移した理由で、
/// ここは既存資産を捨てないための読み取り専用の経路。
public enum GlossaryMarkdownParser {
    public static func entries(from markdown: String) -> [KnowledgeEntry] {
        KnowledgeParser.sections(in: markdown, level: 2).flatMap { section -> [KnowledgeEntry] in
            // 子見出しがあるなら親は分類。「## AI・機械学習関連」を用語にしてしまわない
            let children = KnowledgeParser.sections(in: section.body, level: 3)
            guard children.isEmpty else {
                return children.compactMap(KnowledgeParser.entry(from:))
            }
            return [KnowledgeParser.entry(from: section)].compactMap(\.self)
        }
    }
}
