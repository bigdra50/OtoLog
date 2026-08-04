import Foundation

/// 生成済みの用語集から前提知識候補を集める。
///
/// glossary.md は既に「用語 + 文脈 + 定義」の形で出ているので、そのまま候補になる。
/// ただし説明は AI が書いたもので外れることがある（会議の文脈から
/// 自社アプリを案件名と読み違えた例がある）ため、確定は人の手を通す。
public enum KnowledgeCollector {
    // MARK: Public

    /// knowledge に既にある用語と、一度却下された用語は候補にしない
    public static func collect(
        directory: URL,
        knowledge: [KnowledgeEntry],
        dismissed: [String],
        now: Date
    ) -> [KnowledgeSuggestion] {
        let excluded = Set(knowledge.map(\.term)).union(dismissed)
        var seen = Set<String>()
        var suggestions: [KnowledgeSuggestion] = []

        for glossary in glossaryFiles(in: directory).sorted(by: { $0.path < $1.path }) {
            let origin = origin(of: glossary, under: directory)
            for entry in entries(in: glossary) {
                guard !excluded.contains(entry.term), seen.insert(entry.term).inserted else { continue }
                suggestions.append(KnowledgeSuggestion(
                    term: entry.term, body: stripEmphasis(entry.body), origin: origin, createdAt: now
                ))
            }
        }
        return suggestions
    }

    // MARK: Private

    /// 構造化出力があればそれを使う。Markdown は体裁が定まらないので最後の手段
    private static func entries(in glossary: URL) -> [KnowledgeEntry] {
        let json = glossary.deletingPathExtension().appendingPathExtension("json")
        if let text = try? String(contentsOf: json, encoding: .utf8),
           let document = try? GlossaryDocument(json: text) {
            return document.knowledgeEntries()
        }
        guard let contents = try? String(contentsOf: glossary, encoding: .utf8) else { return [] }
        return GlossaryMarkdownParser.entries(from: PostProcessRunner.stripProvenanceHeader(contents))
    }

    /// 生成物の強調記号を落とす。
    /// 候補は編集欄に生テキストとして出るため記号がそのまま見えてしまい、
    /// プロンプトへ入るぶんも無駄に長くなる
    private static func stripEmphasis(_ body: String) -> String {
        body
            .replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func glossaryFiles(in directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "glossary.md" }
    }

    /// 保存ルートからの相対パス（`2026-07-31/会議`）。人が「何の話だったか」を辿る手がかり。
    ///
    /// 保存先が別ボリュームへのシンボリックリンクだと、走査で返る URL は解決後の実体パスになり、
    /// 設定値のままの root とは前方一致しない。両方を解決してから比べる
    private static func origin(of file: URL, under directory: URL) -> String {
        let session = file.deletingLastPathComponent()
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let path = session.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(root) else { return session.lastPathComponent }
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
