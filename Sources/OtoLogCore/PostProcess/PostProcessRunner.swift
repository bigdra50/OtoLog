import Foundation

// MARK: - PostProcessRunner

/// 後処理生成の統括: jsonl 読込 → ガード → 生成 → サニタイズ → 保存。
/// jsonl は不変の正本で、生成物（<stem>.<templateID>.md）は再実行で上書きされる派生物。
public struct PostProcessRunner: Sendable {
    // MARK: Lifecycle

    public init(
        directory: URL,
        timeZone: TimeZone,
        generator: any TextGenerator,
        correctionStore: CorrectionDictionaryStore? = CorrectionDictionaryStore(),
        maxPromptCharacters: Int = 150_000,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directory = directory
        self.timeZone = timeZone
        self.generator = generator
        self.correctionStore = correctionStore
        self.maxPromptCharacters = maxPromptCharacters
        self.now = now
    }

    // MARK: Public

    /// 生成物先頭の由来コメント行を除いた本文を返す（ビューワー表示・依存出力の受け渡しで共用）
    public static func stripProvenanceHeader(_ contents: String) -> String {
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false)[...]
        if let first = lines.first, first.hasPrefix("<!-- otolog:generated") {
            lines = lines.dropFirst()
        }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines = lines.dropFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 成功時は書き出した生成物の URL を返す
    public func run(session: SessionRef, template: GenerationTemplate) async throws -> URL {
        let segments = try TranscriptReader(directory: directory, timeZone: timeZone).segments(in: session)
        guard !segments.isEmpty else {
            throw PostProcessError.emptyTranscript(session: session.displayName)
        }

        let builder = PromptBuilder(timeZone: timeZone)
        // correct には育てた修正辞書を注入する（自己改善ループの適用側）
        let corrections = template.id == "correct" ? (correctionStore?.load().promptEntries() ?? []) : []
        let prompt = builder.prompt(
            template: template, session: session, segments: segments, corrections: corrections
        )
        guard prompt.count <= maxPromptCharacters else {
            throw PostProcessError.promptTooLarge(characters: prompt.count, limit: maxPromptCharacters)
        }

        let generated = try await generator.generate(prompt: prompt)
        let body = Self.stripWrappingCodeFence(generated)

        let header = "<!-- otolog:generated template=\(template.id) source=transcript.jsonl "
            + "generatedAt=\(Self.iso8601(now())) -->"
        let url = outputURL(session: session, templateID: template.id)
        try (header + "\n\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)

        // correct の成果から修正ペアを学習し辞書を育てる。学習失敗は成果に影響しないため握る
        if template.id == "correct", let correctionStore,
           let corrected = TimestampedLogParser.parse(body),
           let original = TimestampedLogParser.parse(builder.logBody(from: segments)) {
            let pairs = CorrectionExtractor.pairs(original: original, corrected: corrected)
            if !pairs.isEmpty {
                try? correctionStore.record(pairs, now: now())
            }
        }
        return url
    }

    public func outputURL(session: SessionRef, templateID: String) -> URL {
        directory.appendingPathComponent(session.directoryName).appendingPathComponent("\(templateID).md")
    }

    // MARK: Internal

    /// モデルが指示に反して出力全体をコードフェンスで包んだ場合に剥がす（PipelineRunner と共用）
    static func stripWrappingCodeFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2,
              lines.first?.hasPrefix("```") == true,
              lines.last?.hasPrefix("```") == true
        else { return trimmed }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: Private

    private let directory: URL
    private let timeZone: TimeZone
    private let generator: any TextGenerator
    private let correctionStore: CorrectionDictionaryStore?
    private let maxPromptCharacters: Int
    private let now: @Sendable () -> Date
}

// MARK: - PostProcessError

public enum PostProcessError: Error, LocalizedError {
    case emptyTranscript(session: String)
    case promptTooLarge(characters: Int, limit: Int)

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case let .emptyTranscript(session):
            "このセッションに記録がありません: \(session)"
        case let .promptTooLarge(characters, limit):
            "ログが大きすぎます（約\(characters)文字 > 上限\(limit)文字）。分割生成は未対応です"
        }
    }
}
