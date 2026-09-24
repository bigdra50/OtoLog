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

            await coordinator.runPostStopAction(for: empty)
            await coordinator.runPostStopAction(for: noise)

            #expect(state.generationState == .idle)
        }
    }

    @Test func 発話のある記録には停止後の自動処理を走らせる() async throws {
        try await SessionFixture.withTempDir { root in
            let ref = try SessionFixture.make(in: root, name: "2026-07-29/1300", texts: [", , ,", "本文"])
            let (state, settings) = makeStateAndSettings(saveDirectory: root)
            settings.postStopAction = .title
            let coordinator = GenerationCoordinator(state: state, settings: settings)

            await coordinator.runPostStopAction(for: ref)

            #expect(state.generationState == .running(templateName: "タイトル"))
            coordinator.cancel()
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
