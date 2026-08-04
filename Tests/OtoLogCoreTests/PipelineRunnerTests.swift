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

    /// 前提知識は生ログを読むタスクにだけ渡す。
    /// 校正済みログを受け取る下流では表記が既に直っており、積むとプロンプトが膨らむだけになる
    @Test(.timeLimit(.minutes(1))) func knowledgeReachesOnlyTasksReadingRawLog() async throws {
        try await withSessionDir { root, _ in
            let knowledgeFile = root.appendingPathComponent("knowledge.md")
            try "## XREAL AURA\nXREAL 社の Android XR デバイス。\n"
                .write(to: knowledgeFile, atomically: true, encoding: .utf8)
            let playbook = Playbook(id: "p", displayName: "p", tasks: [
                PlaybookTask(templateID: "correct", model: .sonnet),
                PlaybookTask(templateID: "summary", model: .sonnet, dependsOn: ["correct"]),
                PlaybookTask(templateID: "qa", model: .haiku),
            ])
            let generators = [
                "correct": FakeTextGenerator(result: "[13:00:00] 校正済み本文"),
                "summary": FakeTextGenerator(result: "要約結果"),
                "qa": FakeTextGenerator(result: "Q&A結果"),
            ]
            let runner = makeRunner(
                root: root, generators: generators,
                knowledgeStore: KnowledgeStore(fileURL: knowledgeFile)
            )

            for await _ in await runner.run(playbook: playbook, session: session) {}

            #expect(generators["correct"]!.receivedPrompts.first!.contains("XREAL AURA"))
            // qa は correct に依存しないので生ログを読む
            #expect(generators["qa"]!.receivedPrompts.first!.contains("XREAL AURA"))
            #expect(!generators["summary"]!.receivedPrompts.first!.contains("XREAL AURA"))
        }
    }

    /// パイプラインの再実行でも、置き換えた前の版を履歴に残す
    @Test(.timeLimit(.minutes(1))) func rerunKeepsPreviousVersionInHistory() async throws {
        try await withSessionDir { root, sessionDir in
            let playbook = Playbook(id: "p", displayName: "p", tasks: [
                PlaybookTask(templateID: "summary", model: .sonnet),
            ])
            let generator = FakeTextGenerator(result: "1回目")
            let runner = makeRunner(root: root, generators: ["summary": generator])

            for await _ in await runner.run(playbook: playbook, session: session) {}
            generator.result = "2回目"
            for await _ in await runner.run(playbook: playbook, session: session) {}

            let versions = GenerationHistory.versions(of: "summary.md", in: sessionDir)
            #expect(versions.count == 1)
            let previous = try versions.first.map { try String(contentsOf: $0, encoding: .utf8) }
            #expect(previous?.contains("1回目") == true)
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
            // 原文「元の生ログ本文」→ 補正で「元の生ログ抜粋」（本文 → 抜粋 の置換）。
            // 置換元が1文字のペアは辞書化しないので、2文字ぶんが入れ替わる例にしてある。
            // 「本文→文章」のような共通文字を挟む変化は LCS が分割するためペアにならない（仕様）
            let generators = ["correct": FakeTextGenerator(result: "[13:00:00] 元の生ログ抜粋")]
            let dictionaryURL = root.appendingPathComponent("corrections.json")
            let runner = makeRunner(
                root: root, generators: generators,
                correctionStore: CorrectionDictionaryStore(fileURL: dictionaryURL)
            )

            for await _ in await runner.run(playbook: playbook, session: session) {}

            let dictionary = CorrectionDictionaryStore(fileURL: dictionaryURL).load()
            #expect(dictionary.entries.contains { $0.wrong == "本文" && $0.right == "抜粋" })
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

    /// ログ本文がチャンク上限を超える correct は、行境界で分割して複数回生成し出力を結合する。
    /// 63KB の全文書き直しが1ターンの出力上限に収まらず自動継続で timeout した事故の対策
    @Test(.timeLimit(.minutes(1))) func longCorrectSplitsIntoChunksAndJoinsOutputs() async throws {
        try await withSessionDir { root, sessionDir in
            // 1セグメント約40文字 × 6行。上限100文字 → 2行ずつ3チャンクになる
            let lines = try (0..<6).map { index in
                try JSONLCoder.encodeLine(TestFixtures.segment(
                    text: "セグメント\(index)の本文をここに置いて長さを稼ぐテスト用文章",
                    finalizedAt: Date(timeIntervalSince1970: 1_785_297_600 + Double(index))
                ))
            }
            try (lines.joined(separator: "\n") + "\n").write(
                to: sessionDir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8
            )

            let playbook = Playbook(id: "p", displayName: "p", tasks: [
                PlaybookTask(templateID: "correct", model: .sonnet),
            ])
            let generator = FakeTextGenerator(result: "補正済みチャンク")
            let runner = makeRunner(
                root: root, generators: ["correct": generator], correctionChunkCharacters: 100
            )

            var finished: (done: Int, failed: Int, skipped: Int)?
            for await event in await runner.run(playbook: playbook, session: session) {
                if case let .finished(done, failed, skipped) = event {
                    finished = (done, failed, skipped)
                }
            }

            #expect(finished! == (done: 1, failed: 0, skipped: 0))
            #expect(generator.receivedPrompts.count == 3)
            // 各プロンプトは自分のチャンクの行だけを含む
            #expect(generator.receivedPrompts.allSatisfy { $0.contains("セグメント") })
            let promptsJoined = generator.receivedPrompts.joined()
            for index in 0..<6 {
                #expect(promptsJoined.contains("セグメント\(index)の本文"))
            }
            // チャンクは2並列で走るため受信順は不定。順序ではなく「1プロンプト=1チャンク分」で見る
            #expect(generator.receivedPrompts.allSatisfy { prompt in
                (0..<6).count { prompt.contains("セグメント\($0)の本文") } == 2
            })
            // 出力はチャンク数ぶん結合される
            let output = try String(contentsOf: sessionDir.appendingPathComponent("correct.md"), encoding: .utf8)
            let occurrences = output.components(separatedBy: "補正済みチャンク").count - 1
            #expect(occurrences == 3)
        }
    }

    /// 上限以下の correct は従来どおり1回で生成する（不要な分割をしない）
    @Test(.timeLimit(.minutes(1))) func shortCorrectStaysSingleCall() async throws {
        try await withSessionDir { root, _ in
            let playbook = Playbook(id: "p", displayName: "p", tasks: [
                PlaybookTask(templateID: "correct", model: .sonnet),
            ])
            let generator = FakeTextGenerator(result: "補正済み")
            let runner = makeRunner(
                root: root, generators: ["correct": generator], correctionChunkCharacters: 100_000
            )
            for await _ in await runner.run(playbook: playbook, session: session) {}
            #expect(generator.receivedPrompts.count == 1)
        }
    }

    /// ツール実行の問題（権限拒否など）は警告としてタスク状態と meta.json に残る。
    /// 生成物本文の謝罪文でしか異常が分からない状態にしないための記録側
    @Test(.timeLimit(.minutes(1))) func recordsToolIssuesAsWarnings() async throws {
        try await withSessionDir { root, sessionDir in
            let playbook = Playbook(id: "p", displayName: "p", tasks: [
                PlaybookTask(templateID: "references", model: .sonnet, allowsWebResearch: true),
            ])
            let generator = FakeTextGenerator(result: "リンク集")
            generator.toolIssues = [ToolIssue(toolName: "WebSearch", kind: .permissionDenied)]
            let runner = makeRunner(root: root, generators: ["references": generator])

            var doneState: PipelineTaskState?
            for await event in await runner.run(playbook: playbook, session: session) {
                if case let .taskStateChanged(taskID, state) = event,
                   taskID == "references", state.status == .done {
                    doneState = state
                }
            }

            let warning = ToolIssue(toolName: "WebSearch", kind: .permissionDenied).userMessage
            #expect(doneState?.warnings == [warning])
            let meta = try SessionMetaCoder.decode(
                Data(contentsOf: sessionDir.appendingPathComponent("meta.json"))
            )
            #expect(meta.pipeline?["references"]?.warnings == [warning])
        }
    }

    // MARK: Private

    private func makeRunner(
        root: URL,
        generators: [String: FakeTextGenerator],
        maxConcurrent: Int = 2,
        correctionStore: CorrectionDictionaryStore? = nil, // テストから実 config を汚さない
        knowledgeStore: KnowledgeStore? = nil, // 同上。既定のままだと実 config の knowledge.md を読む
        correctionChunkCharacters: Int = 12_000
    ) -> PipelineRunner {
        PipelineRunner(
            saveDirectory: root,
            timeZone: jst,
            generatorFactory: { task in generators[task.templateID] ?? FakeTextGenerator(result: "未定義") },
            correctionStore: correctionStore,
            knowledgeStore: knowledgeStore,
            maxConcurrent: maxConcurrent,
            correctionChunkCharacters: correctionChunkCharacters,
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
