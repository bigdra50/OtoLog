import Foundation

// MARK: - DependencyOutput

/// パイプラインの統合系タスクへ渡す、依存タスクの生成結果。
public struct DependencyOutput: Sendable, Equatable {
    // MARK: Lifecycle

    public init(displayName: String, body: String) {
        self.displayName = displayName
        self.body = body
    }

    // MARK: Public

    public let displayName: String
    public let body: String
}

// MARK: - PromptBuilder

/// テンプレートとセグメント列から LLM へ渡すプロンプトを合成する純関数。LLM 実装には依存しない。
public struct PromptBuilder: Sendable {
    // MARK: Lifecycle

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    // MARK: Public

    public func prompt(
        template: GenerationTemplate,
        session: SessionRef,
        segments: [TranscriptSegment],
        corrections: [CorrectionEntry] = [],
        knowledge: [KnowledgeEntry] = []
    ) -> String {
        prompt(
            template: template, session: session, logBody: logBody(from: segments),
            corrections: corrections, knowledge: knowledge
        )
    }

    /// パイプライン用: ログ本文（校正済みテキスト等）を直接渡し、依存タスクの結果を添付できる
    public func prompt(
        template: GenerationTemplate,
        session: SessionRef,
        logBody: String,
        dependencyOutputs: [DependencyOutput] = [],
        corrections: [CorrectionEntry] = [],
        knowledge: [KnowledgeEntry] = [],
        situation: String = ""
    ) -> String {
        let dependencySection = dependencyOutputs.isEmpty ? "" : "\n## 依存タスクの結果\n" + dependencyOutputs
            .map { "\n### \($0.displayName)\n\($0.body)\n" }
            .joined()
        let correctionSection = corrections.isEmpty ? "" : "\n## 既知の修正辞書（過去の補正で確定した表記。該当があれば従う）\n"
            + corrections.map { "- \($0.wrong) → \($0.right)" }.joined(separator: "\n") + "\n"
        // 語を並べるだけでは何者か分からず、音が近いだけの箇所まで引き寄せる。
        // 何であるかを添えて、文脈の合う箇所だけを直させる
        // 現況は「今どうなっているか」。定義を教える前提知識とは別に、時点つきで渡す
        let situationSection = situation.isEmpty ? "" : "\n## 現在の現況メモ（今回のログを踏まえて更新する対象）\n\(situation)\n"
        let knowledgeSection = knowledge.isEmpty ? "" : "\n## 前提知識（この分野の固有名詞。表記はこれに従い、文脈が合う箇所だけ寄せる）\n"
            + knowledge.map { "\n### \($0.term)\n\($0.body)\n" }.joined()
        return """
        あなたは音声文字起こしログの後処理を行うアシスタントです。以下のルールに厳密に従ってください。
        - 出力は結果の Markdown 本文のみ。前置き・後置き・説明文を書かず、出力全体をコードフェンスで囲まない
        - 出力の言語はログ本文と同じ言語にする
        - ログに存在しない事実を創作しない
        - 強調（**太字**）で見出し代わりにしない。項目を立てたいときは見出しの階層で表す
        - 図で示したほうが分かりやすい構造は ```mermaid のコードブロックで書く
        - ツールが使えない・情報を確認できないなど実行上の問題が起きても、本文で謝罪や許可の要求をしない。\
        得られた情報の範囲で生成指示に沿った成果物を完成させ、確認できなかった箇所は該当箇所への短い注記にとどめる

        ## 生成指示
        \(template.instructions)
        \(knowledgeSection)\(situationSection)\(correctionSection)
        ## 対象データ
        \(session.displayName)（\(startedAtDescription(session.startedAt)) 開始）のシステム音声文字起こしログ。
        1行が1確定セグメントで、行頭の [HH:mm:ss] はローカル時刻。
        \(dependencySection)
        ## ログ
        \(logBody)
        """
    }

    /// タイムスタンプ付きログ行の組み立て（1行1セグメント、text 内改行は空白へ）
    public func logBody(from segments: [TranscriptSegment]) -> String {
        segments
            .map { "[\(timestamp($0.finalizedAt))] \(collapseWhitespace($0.text))" }
            .joined(separator: "\n")
    }

    // MARK: Private

    private let timeZone: TimeZone

    private func timestamp(_ date: Date) -> String {
        // DateFormatter は Sendable でないため保持せず毎回生成する（DailyFileNamer と同じ流儀）
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func startedAtDescription(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func collapseWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
