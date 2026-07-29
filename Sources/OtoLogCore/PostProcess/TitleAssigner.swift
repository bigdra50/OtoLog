import Foundation

// MARK: - TitleAssigner

/// 記録済みセッションへタイトルを付与する:
/// ログ抜粋から生成 → sanitize → meta.json 更新 → ディレクトリリネーム → transcript.md 見出し差し替え。
/// 再実行は既存タイトルを置き換える（派生情報は再生成可能の思想）。
public struct TitleAssigner: Sendable {
    // MARK: Lifecycle

    public init(
        saveDirectory: URL,
        timeZone: TimeZone,
        generator: any TextGenerator,
        correctionStore: CorrectionDictionaryStore? = CorrectionDictionaryStore(),
        maxSampleCharacters: Int = 4000
    ) {
        self.saveDirectory = saveDirectory
        self.timeZone = timeZone
        self.generator = generator
        self.correctionStore = correctionStore
        self.maxSampleCharacters = maxSampleCharacters
    }

    // MARK: Public

    public func assignTitle(to ref: SessionRef) async throws -> SessionRef {
        let reader = TranscriptReader(directory: saveDirectory, timeZone: timeZone)
        let segments = try reader.segments(in: ref)
        guard !segments.isEmpty else {
            throw PostProcessError.emptyTranscript(session: ref.displayName)
        }

        let generated = try await generator.generate(prompt: prompt(for: segments))
        let firstLine = generated
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let unquoted = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: " \"'「」『』“”"))
        guard let title = SessionDirectoryNamer.sanitizeTitle(unquoted) else {
            throw TitleAssignerError.unusableTitle(generated: generated)
        }

        let oldDir = saveDirectory.appendingPathComponent(ref.directoryName)

        var meta = try SessionMetaCoder.decode(Data(contentsOf: oldDir.appendingPathComponent("meta.json")))
        meta.title = title
        try SessionMetaCoder.encode(meta).write(
            to: oldDir.appendingPathComponent("meta.json"), options: .atomic
        )

        // 日付フォルダ内でタイトル名へリネームする（旧フラット構造もここで新構造へ移動する）。
        // 同じ日に同名タイトルがあれば連番を付ける
        let namer = SessionDirectoryNamer(timeZone: timeZone)
        let date = namer.dateComponent(for: ref.startedAt)
        let dateDirectory = saveDirectory.appendingPathComponent(date, isDirectory: true)
        try FileManager.default.createDirectory(at: dateDirectory, withIntermediateDirectories: true)
        var name = title
        var counter = 2
        while FileManager.default.fileExists(atPath: dateDirectory.appendingPathComponent(name).path),
              dateDirectory.appendingPathComponent(name).path != oldDir.path {
            name = "\(title)-\(counter)"
            counter += 1
        }
        let newRelativePath = "\(date)/\(name)"
        let newDir = dateDirectory.appendingPathComponent(name, isDirectory: true)
        if newRelativePath != ref.directoryName {
            try FileManager.default.moveItem(at: oldDir, to: newDir)
        }

        rewriteMarkdownHeading(in: newDir, title: title)
        return SessionRef(directoryName: newRelativePath, title: title, startedAt: ref.startedAt)
    }

    // MARK: Private

    private let saveDirectory: URL
    private let timeZone: TimeZone
    private let generator: any TextGenerator
    private let correctionStore: CorrectionDictionaryStore?
    private let maxSampleCharacters: Int

    private func prompt(for segments: [TranscriptSegment]) -> String {
        let full = segments
            .map { $0.text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
            .joined(separator: "\n")
        // 長いログは先頭と末尾を抜粋する（冒頭の導入と結びで全体像が出る）
        let sample: String = if full.count <= maxSampleCharacters {
            full
        } else {
            full.prefix(maxSampleCharacters * 3 / 4) + "\n…（中略）…\n" + full.suffix(maxSampleCharacters / 4)
        }
        let corrections = correctionStore?.load().promptEntries(limit: 20) ?? []
        let correctionNote = corrections.isEmpty ? "" : "\n- 固有名詞はこの表記対応に従う: "
            + corrections.map { "\($0.wrong)→\($0.right)" }.joined(separator: "、")
        return """
        以下の文字起こしログにふさわしい短いタイトルを1つ生成してください。
        - 内容を最もよく表す具体的な語を使う
        - 15文字程度、最大25文字
        - 出力はタイトルの文字列のみ。引用符・括弧・記号・説明を付けない\(correctionNote)

        ## ログ（抜粋）
        \(sample)
        """
    }

    /// transcript.md の先頭見出し行をタイトルへ差し替える。md が無い・見出しが無い場合は何もしない
    private func rewriteMarkdownHeading(in sessionDirectory: URL, title: String) {
        let url = sessionDirectory.appendingPathComponent("transcript.md")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.hasPrefix("# ") else { return }
        lines[0] = "# \(title)"
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - TitleAssignerError

public enum TitleAssignerError: Error, LocalizedError {
    case unusableTitle(generated: String)

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case let .unusableTitle(generated):
            "生成されたタイトルが使えませんでした: \(generated.prefix(80))"
        }
    }
}
