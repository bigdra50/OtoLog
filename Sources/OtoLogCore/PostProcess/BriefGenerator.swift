import Foundation

// MARK: - BriefGenerator

/// 事前ブリーフの生成: 過去の記録から「これから聞くセッションのための文脈ノート」を作る。
/// 連続聴講（カンファレンスの続き）や定例会議の「前回までのあらすじ」が主用途。
/// 生成物はセッションに紐付かず <保存ルート>/briefs/ に置かれる。
public struct BriefGenerator: Sendable {
    // MARK: Lifecycle

    public init(
        saveDirectory: URL,
        timeZone: TimeZone,
        generator: any TextGenerator,
        maxSessions: Int = 5,
        maxCharactersPerSession: Int = 1500,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.saveDirectory = saveDirectory
        self.timeZone = timeZone
        self.generator = generator
        self.maxSessions = maxSessions
        self.maxCharactersPerSession = maxCharactersPerSession
        self.now = now
    }

    // MARK: Public

    /// topic が nil のときは「直近の記録の続き」を想定した文脈ノートになる
    public func generate(topic: String?) async throws -> URL {
        let reader = TranscriptReader(directory: saveDirectory, timeZone: timeZone)
        let sessions = Array(reader.availableSessions().prefix(maxSessions))
        guard !sessions.isEmpty else {
            throw BriefGeneratorError.noPastSessions
        }

        let materials = sessions.map { session in
            "### \(session.displayName)（\(dateText(session.startedAt))）\n\(material(for: session, reader: reader))"
        }.joined(separator: "\n\n")

        let subject = topic ?? "直近の記録の続きにあたる内容"
        let prompt = """
        これから「\(subject)」を聞く人のための事前ブリーフを作成してください。
        - 出力は結果の Markdown 本文のみ。前置き・説明を書かない
        - 「前回までの要点」「今回注目すると良いポイント」「関連キーワード」の3節で構成する
        - 過去の記録に無い事実を創作しない。関連が薄い記録は無視してよい

        ## 過去の記録（新しい順）
        \(materials)
        """

        let generated = try await generator.generate(prompt: prompt)
        let body = PostProcessRunner.stripWrappingCodeFence(generated)

        let briefsDirectory = saveDirectory.appendingPathComponent("briefs", isDirectory: true)
        try FileManager.default.createDirectory(at: briefsDirectory, withIntermediateDirectories: true)
        let header = "<!-- otolog:generated template=brief source=sessions "
            + "generatedAt=\(PostProcessRunner.iso8601(now())) -->"
        let fileName = SessionDirectoryNamer(timeZone: timeZone).baseName(for: now()) + ".md"
        let url = briefsDirectory.appendingPathComponent(fileName)
        try (header + "\n\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Private

    private let saveDirectory: URL
    private let timeZone: TimeZone
    private let generator: any TextGenerator
    private let maxSessions: Int
    private let maxCharactersPerSession: Int
    private let now: @Sendable () -> Date

    /// セッションの材料: summary があればそれ、なければ digest、なければ transcript の冒頭
    private func material(for session: SessionRef, reader: TranscriptReader) -> String {
        let sessionDirectory = saveDirectory.appendingPathComponent(session.directoryName)
        for candidate in ["summary.md", "digest.md"] {
            let url = sessionDirectory.appendingPathComponent(candidate)
            if let raw = try? String(contentsOf: url, encoding: .utf8) {
                return String(PostProcessRunner.stripProvenanceHeader(raw).prefix(maxCharactersPerSession))
            }
        }
        let segments = (try? reader.segments(in: session)) ?? []
        let head = segments
            .map { $0.text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
            .joined(separator: "\n")
        return String(head.prefix(maxCharactersPerSession))
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - BriefGeneratorError

public enum BriefGeneratorError: Error, LocalizedError {
    case noPastSessions

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case .noPastSessions:
            "ブリーフの材料になる過去の記録がありません。"
        }
    }
}
