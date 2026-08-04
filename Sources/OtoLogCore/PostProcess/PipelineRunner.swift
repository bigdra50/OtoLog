import Foundation

// MARK: - PipelineEvent

/// パイプライン実行の進捗イベント（UI 表示用）。
public enum PipelineEvent: Sendable, Equatable {
    case taskStateChanged(taskID: String, state: PipelineTaskState)
    /// 実行中タスクの生成中テキストの末尾（生存確認のライブ表示用。永続化しない）
    case taskProgress(taskID: String, snippet: String)
    case finished(done: Int, failed: Int, skipped: Int)
}

// MARK: - PipelineRunner

/// プレイブックの依存グラフをトポロジカル順に並列実行する。
/// - 失敗タスクの下流だけを skipped にし、他は続行する
/// - correct に依存する下流タスクは、ログ本文を校正結果に差し替えて実行する
/// - correct 以外の依存出力は「依存タスクの結果」としてプロンプトに添付する（統合系タスク用）
/// - 状態は meta.json に永続化し、`only` 指定で失敗タスクだけの再実行ができる
public actor PipelineRunner {
    // MARK: Lifecycle

    public init(
        saveDirectory: URL,
        timeZone: TimeZone,
        generatorFactory: @escaping @Sendable (PlaybookTask) -> any TextGenerator,
        templateStore: TemplateStore = TemplateStore(),
        correctionStore: CorrectionDictionaryStore? = CorrectionDictionaryStore(),
        knowledgeStore: KnowledgeStore? = KnowledgeStore(),
        maxConcurrent: Int = 2,
        maxPromptCharacters: Int = 150_000,
        correctionChunkCharacters: Int = 12_000,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.saveDirectory = saveDirectory
        self.timeZone = timeZone
        self.generatorFactory = generatorFactory
        self.templateStore = templateStore
        self.correctionStore = correctionStore
        self.knowledgeStore = knowledgeStore
        self.maxConcurrent = maxConcurrent
        self.maxPromptCharacters = maxPromptCharacters
        self.correctionChunkCharacters = correctionChunkCharacters
        self.now = now
    }

    // MARK: Public

    /// 実行を開始し進捗イベント列を返す。only 指定時はそのタスクだけを再実行し、
    /// 依存の充足は meta.json に記録された done とその出力ファイルを再利用する
    public func run(
        playbook: Playbook,
        session: SessionRef,
        only: [String]? = nil
    ) -> AsyncStream<PipelineEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: PipelineEvent.self)
        guard context == nil else {
            continuation.yield(.finished(done: 0, failed: 0, skipped: 0))
            continuation.finish()
            return stream
        }
        runTask = Task {
            await execute(playbook: playbook, session: session, only: only, continuation: continuation)
        }
        return stream
    }

    public func cancel() {
        runTask?.cancel()
    }

    // MARK: Private

    /// TaskGroup の子から返す実行結果。any Error は Sendable でないため文字列化して運ぶ
    private struct TaskOutcome {
        let taskID: String
        let outputFile: String?
        let errorMessage: String?
        /// 完走はしたが成果の質に影響した可能性がある問題（ツールの権限拒否等）
        let warnings: [String]
        let wasCancelled: Bool
    }

    /// 1回の実行に固有のコンテキスト。non-nil なら実行中
    private struct RunContext {
        let playbook: Playbook
        let templates: [GenerationTemplate]
        let session: SessionRef
        let sessionDirectory: URL
        let segments: [TranscriptSegment]
        let continuation: AsyncStream<PipelineEvent>.Continuation
    }

    /// チャンク補正の同時実行数。パイプライン全体の maxConcurrent とは独立
    /// （correct 実行中は下流が依存待ちのため、実プロセス数はほぼこの値に収まる）
    private static let chunkConcurrency = 2

    private let saveDirectory: URL
    private let timeZone: TimeZone
    private let generatorFactory: @Sendable (PlaybookTask) -> any TextGenerator
    private let templateStore: TemplateStore
    private let correctionStore: CorrectionDictionaryStore?
    private let knowledgeStore: KnowledgeStore?
    private let maxConcurrent: Int
    private let maxPromptCharacters: Int

    /// correct のログ本文がこれを超えると行境界で分割し並列補正する。
    /// 全文書き直しの出力が1ターン上限（32K トークン）を超えると自動継続で際限なく延びるため、
    /// 1ターンで確実に収まるサイズに割る（21K 文字は1ターン完走、32K 文字は継続発生の実測から）
    private let correctionChunkCharacters: Int

    private let now: @Sendable () -> Date

    private var runTask: Task<Void, Never>?
    private var context: RunContext?
    private var taskStates: [String: PipelineTaskState] = [:]
    private var pendingIDs: [String] = []
    private var runningCount = 0

    /// 単発生成。streaming 対応の generator なら生成中テキストを onProgress へ流し、
    /// 問題報告対応ならツール実行の問題も受け取る
    private nonisolated static func generate(
        prompt: String,
        with generator: any TextGenerator,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> (text: String, issues: [ToolIssue]) {
        if let reporting = generator as? IssueReportingTextGenerator {
            let throttler = SnippetThrottler(onEmit: onProgress)
            let reported = try await reporting.generateReporting(prompt: prompt) { throttler.append($0) }
            return (reported.text, reported.toolIssues)
        }
        if let streaming = generator as? StreamingTextGenerator {
            let throttler = SnippetThrottler(onEmit: onProgress)
            let text = try await streaming.generate(prompt: prompt) { throttler.append($0) }
            return (text, [])
        }
        let text = try await generator.generate(prompt: prompt)
        return (text, [])
    }

    private func execute(
        playbook: Playbook,
        session: SessionRef,
        only: [String]?,
        continuation: AsyncStream<PipelineEvent>.Continuation
    ) async {
        defer {
            continuation.finish()
            context = nil
        }
        let sessionDirectory = saveDirectory.appendingPathComponent(session.directoryName)
        let templates = templateStore.loadTemplates()
        let segments = (try? TranscriptReader(directory: saveDirectory, timeZone: timeZone)
            .segments(in: session)) ?? []
        context = RunContext(
            playbook: playbook, templates: templates, session: session,
            sessionDirectory: sessionDirectory, segments: segments, continuation: continuation
        )

        // 前回状態は同じプレイブックのときだけ再利用する（別プレイブックの done を依存充足に使わない）
        let previousMeta = readMeta(in: sessionDirectory)
        let previous = (previousMeta?.playbookID == playbook.id ? previousMeta?.pipeline : nil) ?? [:]

        let targetIDs = only ?? playbook.tasks.map(\.id)
        let targetSet = Set(targetIDs)

        taskStates = [:]
        runningCount = 0
        for task in playbook.tasks {
            if targetSet.contains(task.id) {
                taskStates[task.id] = PipelineTaskState(status: .pending)
            } else if let kept = previous[task.id] {
                taskStates[task.id] = kept
            }
        }

        // 初期状態を通知・永続化
        for id in targetIDs {
            setState(id, PipelineTaskState(status: .pending))
        }

        guard !segments.isEmpty else {
            for id in targetIDs {
                setState(id, PipelineTaskState(status: .failed, error: "このセッションに記録がありません"))
            }
            continuation.yield(.finished(done: 0, failed: targetIDs.count, skipped: 0))
            return
        }

        pendingIDs = targetIDs

        await withTaskGroup(of: TaskOutcome.self) { group in
            launchWork(into: &group)
            while runningCount > 0, let outcome = await group.next() {
                runningCount -= 1
                handle(outcome)
                launchWork(into: &group)
            }
        }

        var done = 0, failed = 0, skipped = 0
        for id in targetIDs {
            switch taskStates[id]?.status {
            case .done: done += 1
            case .failed: failed += 1
            case .skipped: skipped += 1
            default: break
            }
        }
        continuation.yield(.finished(done: done, failed: failed, skipped: skipped))
    }

    private func setState(_ taskID: String, _ state: PipelineTaskState) {
        guard let context else { return }
        taskStates[taskID] = state
        writeMeta(in: context.sessionDirectory, playbookID: context.playbook.id, pipeline: taskStates)
        context.continuation.yield(.taskStateChanged(taskID: taskID, state: state))
    }

    private func isReady(_ task: PlaybookTask) -> Bool {
        task.dependsOn.allSatisfy { taskStates[$0]?.status == .done }
    }

    /// 依存先が失敗・スキップ・そもそも実行対象外（記録もない）なら、このタスクは実行できない
    private func isBlocked(_ task: PlaybookTask) -> Bool {
        task.dependsOn.contains { id in
            let status = taskStates[id]?.status
            return status == .failed || status == .skipped || status == nil
        }
    }

    /// 実行不能タスクの skipped 化と、空きスロットへの ready タスク投入
    private func launchWork(into group: inout TaskGroup<TaskOutcome>) {
        guard let context else { return }
        var progressed = true
        while progressed {
            progressed = false
            for id in pendingIDs {
                guard let candidate = context.playbook.tasks.first(where: { $0.id == id }),
                      isBlocked(candidate) else { continue }
                setState(id, PipelineTaskState(status: .skipped))
                progressed = true
            }
            pendingIDs.removeAll { taskStates[$0]?.status != .pending }
        }
        guard !Task.isCancelled else { return }
        for id in pendingIDs {
            guard runningCount < maxConcurrent else { break }
            guard let candidate = context.playbook.tasks.first(where: { $0.id == id }),
                  isReady(candidate) else { continue }
            guard let template = context.templates.first(where: { $0.id == candidate.templateID }) else {
                setState(id, PipelineTaskState(status: .failed, error: "テンプレートがありません: \(id)"))
                continue
            }
            setState(id, PipelineTaskState(status: .running, startedAt: now()))
            runningCount += 1
            let snapshot = taskStates
            let session = context.session
            let sessionDirectory = context.sessionDirectory
            let segments = context.segments
            let taskID = candidate.id
            group.addTask {
                await self.performTask(
                    candidate, template: template, session: session,
                    sessionDirectory: sessionDirectory, segments: segments, states: snapshot,
                    onProgress: { snippet in
                        Task { await self.emitProgress(taskID: taskID, snippet: snippet) }
                    }
                )
            }
        }
        pendingIDs.removeAll { taskStates[$0]?.status != .pending }
    }

    private func handle(_ outcome: TaskOutcome) {
        let startedAt = taskStates[outcome.taskID]?.startedAt
        if outcome.wasCancelled {
            // キャンセルは失敗扱いにせず、再実行可能な pending へ戻す
            setState(outcome.taskID, PipelineTaskState(status: .pending))
        } else if let outputFile = outcome.outputFile {
            setState(outcome.taskID, PipelineTaskState(
                status: .done, outputFile: outputFile,
                warnings: outcome.warnings.isEmpty ? nil : outcome.warnings,
                startedAt: startedAt, finishedAt: now()
            ))
            if outcome.taskID == "correct" {
                learnCorrections(outputFile: outputFile)
            }
        } else {
            setState(outcome.taskID, PipelineTaskState(
                status: .failed, error: outcome.errorMessage, startedAt: startedAt, finishedAt: now()
            ))
        }
    }

    /// correct の成果から修正ペアを学習し辞書を育てる（自己改善ループの学習側）。
    /// 学習失敗は本体の成果に影響しないため握る
    private func learnCorrections(outputFile: String) {
        guard let correctionStore, let context else { return }
        let url = context.sessionDirectory.appendingPathComponent(outputFile)
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let corrected = TimestampedLogParser.parse(PostProcessRunner.stripProvenanceHeader(raw)),
              let original = TimestampedLogParser.parse(
                  PromptBuilder(timeZone: timeZone).logBody(from: context.segments)
              )
        else { return }
        let pairs = CorrectionExtractor.pairs(original: original, corrected: corrected)
        guard !pairs.isEmpty else { return }
        _ = try? correctionStore.record(pairs, now: now())
    }

    /// 実行中タスクのライブ表示。running 以外（完了後の遅延到着）は流さない
    private func emitProgress(taskID: String, snippet: String) {
        guard taskStates[taskID]?.status == .running else { return }
        context?.continuation.yield(.taskProgress(taskID: taskID, snippet: snippet))
    }

    /// 1タスクの生成と書き出し。actor 隔離外で並行実行される
    private nonisolated func performTask(
        _ task: PlaybookTask,
        template: GenerationTemplate,
        session: SessionRef,
        sessionDirectory: URL,
        segments: [TranscriptSegment],
        states: [String: PipelineTaskState],
        onProgress: @escaping @Sendable (String) -> Void
    ) async -> TaskOutcome {
        do {
            let builder = PromptBuilder(timeZone: timeZone)

            // correct に依存し、その出力が使えるなら、ログ本文を校正結果に差し替える
            var logBody = builder.logBody(from: segments)
            var readsCorrectedLog = false
            if task.dependsOn.contains("correct"),
               let correctState = states["correct"], correctState.status == .done,
               let file = correctState.outputFile,
               let corrected = try? String(
                   contentsOf: sessionDirectory.appendingPathComponent(file), encoding: .utf8
               ) {
                logBody = PostProcessRunner.stripProvenanceHeader(corrected)
                readsCorrectedLog = true
            }

            var dependencyOutputs: [DependencyOutput] = []
            for dependency in task.dependsOn where dependency != "correct" {
                guard let state = states[dependency], state.status == .done,
                      let file = state.outputFile,
                      let contents = try? String(
                          contentsOf: sessionDirectory.appendingPathComponent(file), encoding: .utf8
                      )
                else { continue }
                let name = templateStore.loadTemplates().first { $0.id == dependency }?.displayName ?? dependency
                dependencyOutputs.append(DependencyOutput(
                    displayName: name, body: PostProcessRunner.stripProvenanceHeader(contents)
                ))
            }

            // correct タスクには育てた修正辞書を注入する（自己改善ループの適用側）
            let corrections = task.templateID == "correct"
                ? (correctionStore?.load().promptEntries() ?? [])
                : []
            // 前提知識は生ログを読むタスクにだけ渡す。校正済みログを受け取る下流では表記が既に直っており、
            // 話題と無関係な用語まで積むとプロンプトが膨らんで本題の精度が落ちる
            // （実測: 議事録のプロンプトが 25% 膨らみ、デバイス名が別製品へ化けた）
            let knowledge = readsCorrectedLog ? [] : (knowledgeStore?.load() ?? [])
            let generator = generatorFactory(task)
            let generated: String
            var warnings: [String] = []
            if task.templateID == "correct", logBody.count > correctionChunkCharacters {
                // チャンク補正は書き写し系でツールを使わないため、問題収集の対象外
                generated = try await chunkedCorrection(
                    logBody: logBody, template: template, session: session,
                    corrections: corrections, knowledge: knowledge, builder: builder,
                    generator: generator, onProgress: onProgress
                )
            } else {
                let prompt = builder.prompt(
                    template: template, session: session, logBody: logBody,
                    dependencyOutputs: dependencyOutputs, corrections: corrections,
                    knowledge: knowledge
                )
                guard prompt.count <= maxPromptCharacters else {
                    throw PostProcessError.promptTooLarge(characters: prompt.count, limit: maxPromptCharacters)
                }
                let reported = try await Self.generate(prompt: prompt, with: generator, onProgress: onProgress)
                generated = reported.text
                warnings = reported.issues.map(\.userMessage)
            }
            let output = GenerationOutput.files(
                templateID: task.templateID,
                generated: PostProcessRunner.stripWrappingCodeFence(generated)
            )
            let body = output.markdown
            let header = "<!-- otolog:generated template=\(task.templateID) source=transcript.jsonl "
                + "generatedAt=\(PostProcessRunner.iso8601(now())) -->"
            let fileName = "\(task.templateID).md"
            let fileURL = sessionDirectory.appendingPathComponent(fileName)
            // 退避に失敗しても生成そのものは通す。履歴は保険であって成果ではない
            try? GenerationHistory.archive(fileURL, now: now())
            try (header + "\n\n" + body + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            // 構造化出力は機械が読む正本として別に残す（md はここから組み立てた派生物）
            if let json = output.json {
                let jsonURL = sessionDirectory.appendingPathComponent("\(task.templateID).json")
                try? GenerationHistory.archive(jsonURL, now: now())
                try? json.write(to: jsonURL, atomically: true, encoding: .utf8)
            }
            return TaskOutcome(
                taskID: task.id, outputFile: fileName, errorMessage: nil,
                warnings: warnings, wasCancelled: false
            )
        } catch is CancellationError {
            return TaskOutcome(
                taskID: task.id, outputFile: nil, errorMessage: nil, warnings: [], wasCancelled: true
            )
        } catch {
            return TaskOutcome(
                taskID: task.id, outputFile: nil,
                errorMessage: error.localizedDescription, warnings: [], wasCancelled: false
            )
        }
    }

    /// 長い correct を行境界のチャンクへ割り、並列（同時 chunkConcurrency）に補正して index 順に結合する。
    /// 1チャンクでも失敗したらタスク全体を失敗にする（部分結合は行の欠落を生むため）
    private nonisolated func chunkedCorrection(
        logBody: String,
        template: GenerationTemplate,
        session: SessionRef,
        corrections: [CorrectionEntry],
        knowledge: [KnowledgeEntry],
        builder: PromptBuilder,
        generator: any TextGenerator,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let chunks = LogChunker.split(logBody: logBody, maxCharacters: correctionChunkCharacters)
        var results = [String?](repeating: nil, count: chunks.count)
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var nextIndex = 0
            var running = 0
            while nextIndex < chunks.count || running > 0 {
                while nextIndex < chunks.count, running < Self.chunkConcurrency {
                    let index = nextIndex
                    let prompt = builder.prompt(
                        template: template, session: session, logBody: chunks[index],
                        corrections: corrections, knowledge: knowledge
                    )
                    group.addTask {
                        let reported = try await Self.generate(
                            prompt: prompt, with: generator, onProgress: onProgress
                        )
                        return (index, reported.text)
                    }
                    nextIndex += 1
                    running += 1
                }
                guard let (index, text) = try await group.next() else { break }
                // モデルが混ぜる前置き・後書き行（入力に無いタイムスタンプの行）を落として結合する
                results[index] = LogChunker.filterToInputTimestamps(
                    output: PostProcessRunner.stripWrappingCodeFence(text), inputChunk: chunks[index]
                )
                running -= 1
            }
        }
        return results.compactMap(\.self).joined(separator: "\n")
    }

    private func readMeta(in sessionDirectory: URL) -> SessionMeta? {
        guard let data = try? Data(contentsOf: sessionDirectory.appendingPathComponent("meta.json")) else {
            return nil
        }
        return try? SessionMetaCoder.decode(data)
    }

    /// 状態変化のたびに meta.json へ反映する（このランナーが唯一の書き手）。
    /// meta が読めない場合は永続化をあきらめて実行は続ける
    private func writeMeta(in sessionDirectory: URL, playbookID: String, pipeline: [String: PipelineTaskState]) {
        guard var meta = readMeta(in: sessionDirectory) else { return }
        meta.playbookID = playbookID
        meta.pipeline = pipeline
        guard let data = try? SessionMetaCoder.encode(meta) else { return }
        try? data.write(to: sessionDirectory.appendingPathComponent("meta.json"), options: .atomic)
    }
}
