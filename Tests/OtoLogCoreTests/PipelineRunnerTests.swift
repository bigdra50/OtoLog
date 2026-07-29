import Foundation
@testable import OtoLogCore
import Testing

struct PipelineRunnerTests {
    // MARK: Internal

    let jst = TimeZone(identifier: "Asia/Tokyo")!
    let session = SessionRef(
        directoryName: "2026-07-29_1300",
        title: nil,
        startedAt: Date(timeIntervalSince1970: 1_785_297_600)
    )

    /// correct → (summary / qa) → share の依存順に実行し、生成物とイベントを出す
    @Test(.timeLimit(.minutes(1))) func runsTasksInDependencyOrderAndWritesOutputs() async throws {
        try await withSessionDir { root, sessionDir in
            let playbook = Playbook(id: "p", displayName: "p", tasks: [
                PlaybookTask(templateID: "correct", model: .sonnet),
                PlaybookTask(templateID: "summary", model: .sonnet, dependsOn: ["correct"]),
                PlaybookTask(templateID: "qa", model: .haiku, dependsOn: ["correct"]),
                PlaybookTask(templateID: "share", model: .sonnet, dependsOn: ["summary", "qa"]),
            ])
            let generators = [
                "correct": FakeTextGenerator(result: "[13:00:00] 校正済み本文"),
                "summary": FakeTextGenerator(result: "要約結果"),
                "qa": FakeTextGenerator(result: "Q&A結果"),
                "share": FakeTextGenerator(result: "共有結果"),
            ]
            let runner = makeRunner(root: root, generators: generators)

            var transitions: [(String, PipelineTaskState.Status)] = []
            var finished: (done: Int, failed: Int, skipped: Int)?
            for await event in await runner.run(playbook: playbook, session: session) {
                switch event {
                case let .taskStateChanged(taskID, state):
                    transitions.append((taskID, state.status))
                case let .finished(done, failed, skipped):
                    finished = (done, failed, skipped)
                case .taskProgress:
                    break
                }
            }

            #expect(finished! == (done: 4, failed: 0, skipped: 0))
            for id in ["correct", "summary", "qa", "share"] {
                #expect(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("\(id).md").path))
            }
            // 依存順: correct done は summary running より前、share running は summary/qa done より後
            func index(_ id: String, _ status: PipelineTaskState.Status) -> Int? {
                transitions.firstIndex { $0.0 == id && $0.1 == status }
            }
            #expect(index("correct", .done)! < index("summary", .running)!)
            #expect(index("summary", .done)! < index("share", .running)!)
            #expect(index("qa", .done)! < index("share", .running)!)
        }
    }

    /// 下流タスクのログ本文は校正結果に差し替わり、統合タスクは依存出力を受け取る
    @Test(.timeLimit(.minutes(1))) func downstreamUsesCorrectedLogAndIntegrationReceivesDependencyOutputs() async throws {
        try await withSessionDir { root, _ in
            let playbook = Playbook(id: "p", displayName: "p", tasks: [
                PlaybookTask(templateID: "correct", model: .sonnet),
                PlaybookTask(templateID: "summary", model: .sonnet, dependsOn: ["correct"]),
                PlaybookTask(templateID: "share", model: .sonnet, dependsOn: ["summary"]),
            ])
            let generators = [
                "correct": FakeTextGenerator(result: "[13:00:00] 校正済みのユニークな本文XYZ"),
                "summary": FakeTextGenerator(result: "要約のユニークな結果ABC"),
                "share": FakeTextGenerator(result: "共有結果"),
            ]
            let runner = makeRunner(root: root, generators: generators)

            for await _ in await runner.run(playbook: playbook, session: session) {}

            // summary のログ節は元の生ログではなく校正結果
            let summaryPrompt = generators["summary"]!.receivedPrompts.first ?? ""
            #expect(summaryPrompt.contains("校正済みのユニークな本文XYZ"))
            #expect(!summaryPrompt.contains("元の生ログ本文"))
            // share は summary の出力を「依存タスクの結果」として受け取る
            let sharePrompt = generators["share"]!.receivedPrompts.first ?? ""
            #expect(sharePrompt.contains("依存タスクの結果"))
            #expect(sharePrompt.contains("要約のユニークな結果ABC"))
        }
    }

    /// 依存のない並列タスク4つでも同時実行は maxConcurrent に制限される
    @Test(.timeLimit(.minutes(1))) func respectsMaxConcurrentLimit() async throws {
        try await withSessionDir { root, _ in
            let playbook = Playbook(id: "p", displayName: "p", tasks: [
                PlaybookTask(templateID: "summary", model: .sonnet),
                PlaybookTask(templateID: "qa", model: .sonnet),
                PlaybookTask(templateID: "digest", model: .sonnet),
                PlaybookTask(templateID: "minutes", model: .sonnet),
            ])
            let generators = Dictionary(uniqueKeysWithValues: playbook.tasks.map {
                ($0.templateID, FakeTextGenerator(result: "結果", delay: .milliseconds(100)))
            })
            let runner = makeRunner(root: root, generators: generators, maxConcurrent: 2)

            var running = 0
            var maxObserved = 0
            for await event in await runner.run(playbook: playbook, session: session) {
                guard case let .taskStateChanged(_, state) = event else { continue }
                switch state.status {
                case .running:
                    running += 1
                    maxObserved = max(maxObserved, running)
                case .done, .failed, .skipped:
                    running -= 1
                case .pending:
                    break
                }
            }
            #expect(maxObserved <= 2)
        }
    }

    /// 失敗タスクの下流だけ skipped になり、独立タスクは実行される
    @Test(.timeLimit(.minutes(1))) func failedTaskSkipsOnlyItsDownstream() async throws {
        try await withSessionDir { root, _ in
            struct Offline: Error {}
            let playbook = Playbook(id: "p", displayName: "p", tasks: [
                PlaybookTask(templateID: "correct", model: .sonnet),
                PlaybookTask(templateID: "summary", model: .sonnet, dependsOn: ["correct"]),
                PlaybookTask(templateID: "digest", model: .sonnet),
            ])
            let failing = FakeTextGenerator()
            failing.errorToThrow = Offline()
            let generators = [
                "correct": failing,
                "summary": FakeTextGenerator(result: "使われない"),
                "digest": FakeTextGenerator(result: "独立して成功"),
            ]
            let runner = makeRunner(root: root, generators: generators)

            var finished: (done: Int, failed: Int, skipped: Int)?
            var finalStates: [String: PipelineTaskState.Status] = [:]
            for await event in await runner.run(playbook: playbook, session: session) {
                switch event {
                case let .taskStateChanged(taskID, state):
                    finalStates[taskID] = state.status
                case let .finished(done, failed, skipped):
                    finished = (done, failed, skipped)
                case .taskProgress:
                    break
                }
            }

            #expect(finished! == (done: 1, failed: 1, skipped: 1))
            #expect(finalStates["correct"] == .failed)
            #expect(finalStates["summary"] == .skipped)
            #expect(finalStates["digest"] == .done)
            #expect(generators["summary"]!.receivedPrompts.isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1))) func cancelReturnsRunningTasksToPending() async throws {
        try await withSessionDir { root, _ in
            let playbook = Playbook(id: "p", displayName: "p", tasks: [
                PlaybookTask(templateID: "summary", model: .sonnet),
            ])
            let generators = ["summary": FakeTextGenerator(result: "遅い", delay: .seconds(30))]
            let runner = makeRunner(root: root, generators: generators)

            let stream = await runner.run(playbook: playbook, session: session)
            let collector = Task {
                var last: [String: PipelineTaskState.Status] = [:]
                for await event in stream {
                    if case let .taskStateChanged(taskID, state) = event {
                        last[taskID] = state.status
                    }
                }
                return last
            }
            try await Task.sleep(for: .milliseconds(200))
            await runner.cancel()

            let finalStates = await collector.value
            #expect(finalStates["summary"] == .pending)
        }
    }

    @Test(.timeLimit(.minutes(1))) func persistsStatesIntoMetaJSON() async throws {
        try await withSessionDir { root, sessionDir in
            let playbook = Playbook(id: "mini", displayName: "mini", tasks: [
                PlaybookTask(templateID: "summary", model: .sonnet),
            ])
            let runner = makeRunner(root: root, generators: ["summary": FakeTextGenerator(result: "結果")])

            for await _ in await runner.run(playbook: playbook, session: session) {}

            let meta = try SessionMetaCoder.decode(Data(contentsOf: sessionDir.appendingPathComponent("meta.json")))
            #expect(meta.playbookID == "mini")
            #expect(meta.pipeline?["summary"]?.status == .done)
            #expect(meta.pipeline?["summary"]?.outputFile == "summary.md")
        }
    }

    /// ストリーミング対応 generator の生成中テキストが taskProgress として流れる
    @Test(.timeLimit(.minutes(1))) func emitsTaskProgressFromStreamingGenerator() async throws {
        try await withSessionDir { root, _ in
            let playbook = Playbook(id: "p", displayName: "p", tasks: [
                PlaybookTask(templateID: "summary", model: .sonnet),
            ])
            let generator = FakeTextGenerator(result: "要約結果")
            generator.partials = ["生成中の", "テキスト片"]
            let runner = makeRunner(root: root, generators: ["summary": generator])

            var snippets: [String] = []
            for await event in await runner.run(playbook: playbook, session: session) {
                if case let .taskProgress(taskID, snippet) = event {
                    #expect(taskID == "summary")
                    snippets.append(snippet)
                }
            }
            #expect(!snippets.isEmpty)
        }
    }

    /// correct 完了時に原文との diff から修正ペアを学習し、辞書を育てる
    @Test(.timeLimit(.minutes(1))) func learnsCorrectionsAfterCorrectTaskCompletes() async throws {
        try await withSessionDir { root, _ in
            let playbook = Playbook(id: "p", displayName: "p", tasks: [
                PlaybookTask(templateID: "correct", model: .sonnet),
            ])
            // 原文「元の生ログ本文」→ 補正で「元の生ログ短文」（本 → 短 の置換）。
            // 「本文→文章」のような共通文字を挟む変化は LCS が分割するためペアにならない（仕様）
            let generators = ["correct": FakeTextGenerator(result: "[13:00:00] 元の生ログ短文")]
            let dictionaryURL = root.appendingPathComponent("corrections.json")
            let runner = makeRunner(
                root: root, generators: generators,
                correctionStore: CorrectionDictionaryStore(fileURL: dictionaryURL)
            )

            for await _ in await runner.run(playbook: playbook, session: session) {}

            let dictionary = CorrectionDictionaryStore(fileURL: dictionaryURL).load()
            #expect(dictionary.entries.contains { $0.wrong == "本" && $0.right == "短" })
        }
    }

    /// 失敗タスクだけの再実行は、既 done の上流成果物を再利用する
    @Test(.timeLimit(.minutes(1))) func onlyRerunsSpecifiedTasksReusingPreviousOutputs() async throws {
        try await withSessionDir { root, sessionDir in
            let playbook = Playbook(id: "p", displayName: "p", tasks: [
                PlaybookTask(templateID: "correct", model: .sonnet),
                PlaybookTask(templateID: "summary", model: .sonnet, dependsOn: ["correct"]),
            ])
            // 前回実行: correct は done で出力あり、summary は failed
            try "<!-- otolog:generated template=correct source=transcript.jsonl generatedAt=2026-07-29T04:10:00Z -->\n\n[13:00:00] 前回の校正結果DEF\n"
                .write(to: sessionDir.appendingPathComponent("correct.md"), atomically: true, encoding: .utf8)
            var meta = try SessionMetaCoder.decode(Data(contentsOf: sessionDir.appendingPathComponent("meta.json")))
            meta.playbookID = "p"
            meta.pipeline = [
                "correct": PipelineTaskState(status: .done, outputFile: "correct.md"),
                "summary": PipelineTaskState(status: .failed, error: "前回失敗"),
            ]
            try SessionMetaCoder.encode(meta).write(to: sessionDir.appendingPathComponent("meta.json"))

            let correctGenerator = FakeTextGenerator(result: "再実行されないはず")
            let summaryGenerator = FakeTextGenerator(result: "再実行の要約")
            let runner = makeRunner(
                root: root, generators: ["correct": correctGenerator, "summary": summaryGenerator]
            )

            var finished: (done: Int, failed: Int, skipped: Int)?
            for await event in await runner.run(playbook: playbook, session: session, only: ["summary"]) {
                if case let .finished(done, failed, skipped) = event {
                    finished = (done, failed, skipped)
                }
            }

            #expect(finished! == (done: 1, failed: 0, skipped: 0))
            #expect(correctGenerator.receivedPrompts.isEmpty)
            // 再利用された correct 出力がログ本文に使われる
            #expect(summaryGenerator.receivedPrompts.first?.contains("前回の校正結果DEF") == true)
            let updated = try SessionMetaCoder.decode(
                Data(contentsOf: sessionDir.appendingPathComponent("meta.json"))
            )
            #expect(updated.pipeline?["summary"]?.status == .done)
            #expect(updated.pipeline?["correct"]?.status == .done)
        }
    }

    // MARK: Private

    private func makeRunner(
        root: URL,
        generators: [String: FakeTextGenerator],
        maxConcurrent: Int = 2,
        correctionStore: CorrectionDictionaryStore? = nil // テストから実 config を汚さない
    ) -> PipelineRunner {
        PipelineRunner(
            saveDirectory: root,
            timeZone: jst,
            generatorFactory: { task in generators[task.templateID] ?? FakeTextGenerator(result: "未定義") },
            correctionStore: correctionStore,
            maxConcurrent: maxConcurrent,
            now: { Date(timeIntervalSince1970: 1_785_297_600) }
        )
    }

    /// セッションディレクトリ（meta + transcript）を用意する
    private func withSessionDir(_ body: (URL, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogTests-\(UUID().uuidString)", isDirectory: true)
        let sessionDir = root.appendingPathComponent(session.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meta = SessionMeta(
            sessionID: UUID(), startedAt: session.startedAt, locale: "ja-JP", source: .system
        )
        try SessionMetaCoder.encode(meta).write(to: sessionDir.appendingPathComponent("meta.json"))
        let line = try JSONLCoder.encodeLine(TestFixtures.segment(text: "元の生ログ本文"))
        try (line + "\n").write(
            to: sessionDir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8
        )
        try await body(root, sessionDir)
    }
}
