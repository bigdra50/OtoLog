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
    return (AppState(), settings)
}
