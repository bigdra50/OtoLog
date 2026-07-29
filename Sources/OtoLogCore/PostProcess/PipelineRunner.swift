import Foundation

// MARK: - PipelineEvent

/// パイプライン実行の進捗イベント（UI 表示用）。
public enum PipelineEvent: Sendable, Equatable {
    case taskStateChanged(taskID: String, state: PipelineTaskState)
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
        maxConcurrent: Int = 2,
        maxPromptCharacters: Int = 150_000,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.saveDirectory = saveDirectory
        self.timeZone = timeZone
        self.generatorFactory = generatorFactory
        self.templateStore = templateStore
        self.correctionStore = correctionStore
        self.maxConcurrent = maxConcurrent
        self.maxPromptCharacters = maxPromptCharacters
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

    private let saveDirectory: URL
    private let timeZone: TimeZone
    private let generatorFactory: @Sendable (PlaybookTask) -> any TextGenerator
    private let templateStore: TemplateStore
    private let correctionStore: CorrectionDictionaryStore?
    private let maxConcurrent: Int
    private let maxPromptCharacters: Int
    private let now: @Sendable () -> Date

    private var runTask: Task<Void, Never>?
    private var context: RunContext?
    private var taskStates: [String: PipelineTaskState] = [:]
    private var pendingIDs: [String] = []
    private var runningCount = 0

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
            group.addTask {
                await self.performTask(
                    candidate, template: template, session: session,
                    sessionDirectory: sessionDirectory, segments: segments, states: snapshot
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
                status: .done, outputFile: outputFile, startedAt: startedAt, finishedAt: now()
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
        try? correctionStore.record(pairs, now: now())
    }

    /// 1タスクの生成と書き出し。actor 隔離外で並行実行される
    private nonisolated func performTask(
        _ task: PlaybookTask,
        template: GenerationTemplate,
        session: SessionRef,
        sessionDirectory: URL,
        segments: [TranscriptSegment],
        states: [String: PipelineTaskState]
    ) async -> TaskOutcome {
        do {
            let builder = PromptBuilder(timeZone: timeZone)

            // correct に依存し、その出力が使えるなら、ログ本文を校正結果に差し替える
            var logBody = builder.logBody(from: segments)
            if task.dependsOn.contains("correct"),
               let correctState = states["correct"], correctState.status == .done,
               let file = correctState.outputFile,
               let corrected = try? String(
                   contentsOf: sessionDirectory.appendingPathComponent(file), encoding: .utf8
               ) {
                logBody = PostProcessRunner.stripProvenanceHeader(corrected)
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
            let prompt = builder.prompt(
                template: template, session: session, logBody: logBody,
                dependencyOutputs: dependencyOutputs, corrections: corrections
            )
            guard prompt.count <= maxPromptCharacters else {
                throw PostProcessError.promptTooLarge(characters: prompt.count, limit: maxPromptCharacters)
            }

            let generated = try await generatorFactory(task).generate(prompt: prompt)
            let body = PostProcessRunner.stripWrappingCodeFence(generated)
            let header = "<!-- otolog:generated template=\(task.templateID) source=transcript.jsonl "
                + "generatedAt=\(PostProcessRunner.iso8601(now())) -->"
            let fileName = "\(task.templateID).md"
            try (header + "\n\n" + body + "\n").write(
                to: sessionDirectory.appendingPathComponent(fileName), atomically: true, encoding: .utf8
            )
            return TaskOutcome(taskID: task.id, outputFile: fileName, errorMessage: nil, wasCancelled: false)
        } catch is CancellationError {
            return TaskOutcome(taskID: task.id, outputFile: nil, errorMessage: nil, wasCancelled: true)
        } catch {
            return TaskOutcome(
                taskID: task.id, outputFile: nil,
                errorMessage: error.localizedDescription, wasCancelled: false
            )
        }
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
