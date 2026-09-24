import Foundation
@testable import OtoLogApp
import OtoLogCore
import Testing

// MARK: - GenerationCoordinatorLoadTests

/// GenerationCoordinator の保存先走査（async 化後の完了待ちと状態反映）を検証する。
@MainActor struct GenerationCoordinatorLoadTests {
    @Test func refreshは完了時点でセッション一覧を反映している() async throws {
        try await SessionFixture.withTempDir { root in
            try SessionFixture.make(in: root, name: "2026-07-29/1300", texts: ["本文"])
            let (state, settings) = makeStateAndSettings(saveDirectory: root)
            let coordinator = GenerationCoordinator(state: state, settings: settings)

            await coordinator.refresh()

            #expect(state.generationSessions.map(\.directoryName) == ["2026-07-29/1300"])
            #expect(!state.generationTemplates.isEmpty)
        }
    }

    /// 無音で自動停止した記録など、発話の無い記録にタイトル生成を走らせると必ず失敗し、その失敗だけが表示に残る。
    /// 何も保存していない記録（transcript.jsonl が無い）と、雑音に対する句読点だけの結果しか無い記録の両方で確かめる
    @Test(arguments: [PostStopAction.title, .titleAndPipeline]) func 発話の無い記録には停止後の自動処理を走らせない(action: PostStopAction) async throws {
        try await SessionFixture.withTempDir { root in
            let empty = try SessionFixture.makeWithoutTranscript(in: root, name: "2026-07-29/1300")
            let noise = try SessionFixture.make(in: root, name: "2026-07-29/1400", texts: [", , ,", "…"])
            let (state, settings) = makeStateAndSettings(saveDirectory: root)
            settings.postStopAction = action
            let coordinator = GenerationCoordinator(state: state, settings: settings)

            await coordinator.runPostStopAction(for: empty, in: root)
            await coordinator.runPostStopAction(for: noise, in: root)

            #expect(state.generationState == .idle)
        }
    }

    @Test func 発話のある記録には停止後の自動処理を走らせる() async throws {
        try await SessionFixture.withTempDir { root in
            let ref = try SessionFixture.make(in: root, name: "2026-07-29/1300", texts: [", , ,", "本文"])
            let (state, settings) = makeStateAndSettings(saveDirectory: root)
            settings.postStopAction = .title
            let coordinator = GenerationCoordinator(state: state, settings: settings)

            await coordinator.runPostStopAction(for: ref, in: root)

            #expect(state.generationState == .running(templateName: "タイトル"))
            coordinator.cancel()
        }
    }

    /// 保存先は記録を閉じ終えると変えられるが、停止後の自動処理は claude を待ちながら続く。
    /// 途中で変えられても、タイトル生成・プレイブックの判定・パイプラインは閉じた記録が書かれた保存先で進める。
    /// パイプラインが走り始めると、その記録の meta.json にプレイブックが書かれる
    @Test(arguments: [true, false]) func 停止後の自動処理は閉じたときの保存先で進める(choosesPlaybookByContent: Bool) async throws {
        try await SessionFixture.withTempDir { root in
            let ref = try SessionFixture.make(in: root, name: "2026-07-29/1300", texts: ["本文"])
            let (state, settings) = makeStateAndSettings(saveDirectory: root)
            settings.postStopAction = .titleAndPipeline
            settings.defaultPlaybookID = choosesPlaybookByContent ? AppSettings.autoPlaybookID : "lecture"
            settings.claudeExecutablePath = try makeClaudeAnsweringLecture(in: root).path
            let generation = GenerationCoordinator(state: state, settings: settings)
            let pipeline = PipelineCoordinator(state: state, settings: settings)
            generation.pipeline = pipeline

            generation.handleSessionFinished(ref)
            settings.saveDirectoryPath = root.appendingPathComponent("elsewhere", isDirectory: true).path

            let dateDirectory = root.appendingPathComponent("2026-07-29", isDirectory: true)
            #expect(await eventually(timeout: .seconds(10)) { playbookIDs(under: dateDirectory) == ["lecture"] })
            // パイプラインのタスクは偽の claude の答えを読めずに終わる。一時フォルダを消す前に走り終えるのを待つ
            #expect(await eventually(timeout: .seconds(10)) { await MainActor.run { !state.pipelineRunning } })
        }
    }

    @Test func refreshStewardは完了時点で未処理セッションを反映している() async throws {
        try await SessionFixture.withTempDir { root in
            // title 未付与 + playbook 未実行 = 未処理として検出される
            try SessionFixture.make(in: root, name: "2026-07-29/1300", texts: ["本文"])
            let (state, settings) = makeStateAndSettings(saveDirectory: root)
            let coordinator = GenerationCoordinator(state: state, settings: settings)

            await coordinator.refreshSteward()

            #expect(state.stewardFindings.map(\.session.directoryName) == ["2026-07-29/1300"])
            #expect(state.stewardFindings.first?.needsTitle == true)
        }
    }
}

// MARK: - PipelineCoordinatorLoadTests

/// PipelineCoordinator.loadStates の meta.json 復元を検証する。
@MainActor struct PipelineCoordinatorLoadTests {
    @Test func 前回実行の状態を復元しrunningはpendingへ戻す() async throws {
        try await SessionFixture.withTempDir { root in
            let ref = try SessionFixture.make(
                in: root, name: "2026-07-29/1300", texts: ["本文"],
                playbookID: "pb",
                pipeline: [
                    "a": PipelineTaskState(status: .done),
                    "b": PipelineTaskState(status: .running),
                ]
            )
            let (state, settings) = makeStateAndSettings(saveDirectory: root)
            state.pipelinePlaybooks = [Playbook(
                id: "pb", displayName: "PB",
                tasks: [
                    PlaybookTask(templateID: "a", model: .haiku),
                    PlaybookTask(templateID: "b", model: .haiku),
                ]
            )]
            let coordinator = PipelineCoordinator(state: state, settings: settings)

            await coordinator.loadStates(for: ref)

            #expect(state.pipelineTasks.map(\.id) == ["a", "b"])
            #expect(state.pipelineTasks.map(\.state.status) == [.done, .pending])
        }
    }

    @Test func meta欠損では空へ戻す() async throws {
        try await SessionFixture.withTempDir { root in
            let (state, settings) = makeStateAndSettings(saveDirectory: root)
            state.pipelineTasks = [PipelineTaskDisplay(
                id: "stale", displayName: "stale", state: PipelineTaskState(status: .done)
            )]
            let coordinator = PipelineCoordinator(state: state, settings: settings)

            let ref = SessionRef(directoryName: "2026-07-29/1300", title: nil, startedAt: Date())
            await coordinator.loadStates(for: ref)

            #expect(state.pipelineTasks.isEmpty)
        }
    }
}

/// どの問い合わせにも lecture と答える claude。タイトル生成とプレイブックの判定はこの答えで進む
private func makeClaudeAnsweringLecture(in root: URL) throws -> URL {
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let script = bin.appendingPathComponent("claude")
    try "#!/bin/sh\nprintf lecture\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

/// 日付フォルダの下にある記録それぞれの meta.json から、走らせたプレイブックを読む
private func playbookIDs(under dateDirectory: URL) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dateDirectory.path)) ?? []
    return names.sorted().compactMap { name in
        let metaURL = dateDirectory.appendingPathComponent(name).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? SessionMetaCoder.decode(data).playbookID
    }
}

/// 実利用中の UserDefaults を汚さない設定と、fixture の保存先を向いた状態の組
@MainActor private func makeStateAndSettings(saveDirectory: URL) -> (AppState, AppSettings) {
    let suite = "OtoLogAppTests.load-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let settings = AppSettings(defaults: defaults)
    settings.saveDirectoryPath = saveDirectory.path
    // claude は起動させない。存在しないパスなので、生成が走り出しても実行ファイルが見つからずに終わる
    settings.claudeExecutablePath = saveDirectory.appendingPathComponent("missing-claude").path
    return (AppState(), settings)
}
