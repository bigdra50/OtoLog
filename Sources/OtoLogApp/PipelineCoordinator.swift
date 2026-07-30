import Foundation
import OtoLogCore

/// パイプライン実行の起動・キャンセルと AppState への進捗反映だけを行う薄いブリッジ。
/// 実行ロジックは OtoLogCore の PipelineRunner に置く。
@MainActor final class PipelineCoordinator {
    // MARK: Lifecycle

    init(state: AppState, settings: AppSettings) {
        self.state = state
        self.settings = settings
    }

    // MARK: Internal

    /// 生成セクションの展開時に呼ぶ。プレイブック一覧を読み直す
    func refresh() {
        state.pipelinePlaybooks = PlaybookStore().loadPlaybooks()
    }

    /// セッション選択時に、前回実行の状態を meta.json から復元して表示する
    func loadStates(for session: SessionRef) async {
        let metaURL = settings.saveDirectory
            .appendingPathComponent(session.directoryName)
            .appendingPathComponent("meta.json")
        let loaded = await OffMainIO.read { () -> (SessionMeta, [GenerationTemplate])? in
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? SessionMetaCoder.decode(data) else { return nil }
            return (meta, TemplateStore().loadTemplates())
        }
        guard let (meta, templates) = loaded,
              let playbookID = meta.playbookID,
              let playbook = state.pipelinePlaybooks.first(where: { $0.id == playbookID }),
              let pipeline = meta.pipeline
        else {
            state.pipelineTasks = []
            return
        }
        state.pipelineTasks = playbook.tasks.compactMap { task in
            guard var taskState = pipeline[task.id] else { return nil }
            // アプリ強制終了などで running のまま残った状態は再実行可能な pending として見せる
            if taskState.status == .running {
                taskState.status = .pending
            }
            return PipelineTaskDisplay(
                id: task.id,
                displayName: templates.first { $0.id == task.templateID }?.displayName ?? task.templateID,
                state: taskState
            )
        }
    }

    func run(playbook: Playbook, session: SessionRef, only: [String]? = nil) {
        guard !state.pipelineRunning else { return }
        state.pipelineRunning = true

        let templates = TemplateStore().loadTemplates()
        if only == nil {
            state.pipelineTasks = playbook.tasks.map { task in
                PipelineTaskDisplay(
                    id: task.id,
                    displayName: templates.first { $0.id == task.templateID }?.displayName ?? task.templateID,
                    state: PipelineTaskState(status: .pending)
                )
            }
        }

        let executableURL = settings.claudeExecutableURL
        let runner = PipelineRunner(
            saveDirectory: settings.saveDirectory,
            timeZone: .current,
            generatorFactory: { task in
                ClaudeCLIGenerator(
                    executableURL: executableURL,
                    arguments: ClaudeCLIGenerator.arguments(
                        model: task.model, allowWebResearch: task.allowsWebResearch
                    )
                )
            }
        )
        self.runner = runner

        pipelineTask = Task { [state] in
            let stream = await runner.run(playbook: playbook, session: session, only: only)
            for await event in stream {
                switch event {
                case let .taskStateChanged(taskID, taskState):
                    if let index = state.pipelineTasks.firstIndex(where: { $0.id == taskID }) {
                        state.pipelineTasks[index].state = taskState
                        if taskState.status != .running {
                            state.pipelineTasks[index].snippet = nil
                        }
                    } else {
                        state.pipelineTasks.append(PipelineTaskDisplay(
                            id: taskID,
                            displayName: templates.first { $0.id == taskID }?.displayName ?? taskID,
                            state: taskState
                        ))
                    }
                case let .taskProgress(taskID, snippet):
                    if let index = state.pipelineTasks.firstIndex(where: { $0.id == taskID }) {
                        state.pipelineTasks[index].snippet = snippet
                    }
                case .finished:
                    break
                }
            }
            state.pipelineRunning = false
        }
    }

    func retryFailed(playbook: Playbook, session: SessionRef) {
        let failedIDs = state.pipelineTasks.filter { $0.state.status == .failed }.map(\.id)
        guard !failedIDs.isEmpty else { return }
        run(playbook: playbook, session: session, only: failedIDs)
    }

    func cancel() {
        Task { [runner] in
            await runner?.cancel()
        }
    }

    // MARK: Private

    private let state: AppState
    private let settings: AppSettings
    private var runner: PipelineRunner?
    private var pipelineTask: Task<Void, Never>?
}
