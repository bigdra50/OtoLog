import Foundation

// MARK: - SessionClassifier

/// 記録内容の抜粋から、適用すべきプレイブックを選ぶ。
/// 候補の id と説明を提示して1語で答えさせ、どれにも当てはまらなければ nil（勝手に実行しない）。
public struct SessionClassifier: Sendable {
    // MARK: Lifecycle

    public init(
        saveDirectory: URL,
        timeZone: TimeZone,
        generator: any TextGenerator,
        maxSampleCharacters: Int = 4000
    ) {
        self.saveDirectory = saveDirectory
        self.timeZone = timeZone
        self.generator = generator
        self.maxSampleCharacters = maxSampleCharacters
    }

    // MARK: Public

    public func classify(session: SessionRef, candidates: [Playbook]) async throws -> Playbook? {
        guard !candidates.isEmpty else { return nil }
        let reader = TranscriptReader(directory: saveDirectory, timeZone: timeZone)
        let segments = try reader.segments(in: session)
        guard !segments.isEmpty else { return nil }

        let answer = try await generator.generate(prompt: prompt(segments: segments, candidates: candidates))
        let normalized = answer
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted) ?? ""
        return candidates.first { $0.id == normalized }
    }

    // MARK: Private

    private let saveDirectory: URL
    private let timeZone: TimeZone
    private let generator: any TextGenerator
    private let maxSampleCharacters: Int

    private func prompt(segments: [TranscriptSegment], candidates: [Playbook]) -> String {
        let candidateList = candidates
            .map { "- \($0.id): \($0.displayName)。\($0.description)" }
            .joined(separator: "\n")
        let full = segments
            .map { $0.text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
            .joined(separator: "\n")
        let sample: String = if full.count <= maxSampleCharacters {
            full
        } else {
            full.prefix(maxSampleCharacters * 3 / 4) + "\n…（中略）…\n" + full.suffix(maxSampleCharacters / 4)
        }
        return """
        以下の文字起こしログの内容に最も合う分類を1つ選んでください。

        候補:
        \(candidateList)

        出力は分類の id のみ（例: \(candidates[0].id)）。どれにも当てはまらない場合は none と出力してください。説明・引用符・記号は付けないでください。

        ## ログ（抜粋）
        \(sample)
        """
    }
}
