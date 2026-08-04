import AppKit
import Foundation
import OtoLogCore

/// 後処理生成の起動・キャンセルと AppState への状態反映だけを行う薄いブリッジ。
/// RecordingCoordinator と対になる存在で、ロジックは OtoLogCore の PostProcessRunner に置く。
@MainActor final class GenerationCoordinator {
    // MARK: Lifecycle

    init(state: AppState, settings: AppSettings) {
        self.state = state
        self.settings = settings
    }

    // MARK: Internal

    /// 停止時の自動連鎖でパイプラインを起動するための参照（AppDelegate が配線する）
    weak var pipeline: PipelineCoordinator?

    /// 生成セクションの展開時に呼ぶ。対象セッションとテンプレートを読み直す
    func refresh() async {
        let directory = settings.saveDirectory
        let (sessions, templates) = await OffMainIO.read {
            (
                TranscriptReader(directory: directory, timeZone: .current).availableSessions(),
                TemplateStore().loadTemplates()
            )
        }
        state.generationSessions = sessions
        state.generationTemplates = templates
    }

    func generate(session: SessionRef, template: GenerationTemplate) {
        if case .running = state.generationState { return } // 同時実行は1件
        state.generationState = .running(templateName: template.displayName)
        let runner = PostProcessRunner(
            directory: settings.saveDirectory,
            timeZone: .current,
            // スキーマ付きのテンプレートは構造化出力で受け取る
            generator: ClaudeCLIGenerator(
                executableURL: settings.claudeExecutableURL,
                arguments: ClaudeCLIGenerator.arguments(
                    model: nil,
                    allowWebResearch: template.allowsWebResearch,
                    jsonSchema: template.jsonSchema
                )
            )
        )
        generationTask = Task { [state] in
            do {
                let url = try await runner.run(session: session, template: template)
                state.generationState = .finished(url)
            } catch is CancellationError {
                state.generationState = .idle // キャンセルは失敗扱いにしない
            } catch {
                state.generationState = .failed(error.localizedDescription)
            }
        }
    }

    /// セッションのタイトルを生成して付与する（meta 更新 + ディレクトリリネーム）。
    /// 軽量タスクなので haiku を指定する。成功時はリネーム後の参照で completion を呼ぶ
    func assignTitle(session: SessionRef, onSuccess: (@MainActor (SessionRef) -> Void)? = nil) {
        if case .running = state.generationState { return }
        state.generationState = .running(templateName: "タイトル")
        let assigner = TitleAssigner(
            saveDirectory: settings.saveDirectory,
            timeZone: .current,
            generator: ClaudeCLIGenerator(
                executableURL: settings.claudeExecutableURL,
                arguments: ClaudeCLIGenerator.arguments(model: .haiku, allowWebResearch: false)
            )
        )
        generationTask = Task { [state, weak self] in
            do {
                let renamed = try await assigner.assignTitle(to: session)
                state.generationState = .idle
                await self?.refresh() // リネーム後の一覧へ更新
                onSuccess?(renamed)
            } catch is CancellationError {
                state.generationState = .idle
            } catch {
                state.generationState = .failed(error.localizedDescription)
            }
        }
    }

    /// 記録停止時のフック。一覧を更新し、設定に応じて自動処理を連鎖する。
    /// タイトル生成が失敗した場合はパイプラインへ連鎖しない（手動で対処する）
    func handleSessionFinished(_ ref: SessionRef) {
        Task { [weak self] in
            await self?.refresh()
        }
        switch settings.postStopAction {
        case .none:
            break
        case .title:
            assignTitle(session: ref)
        case .titleAndPipeline:
            assignTitle(session: ref) { [weak self] renamed in
                self?.runDefaultPlaybook(session: renamed)
            }
        }
    }

    /// 未処理（タイトルなし/パイプライン未実行）セッションを検出して表示用状態を更新する
    func refreshSteward() async {
        let steward = SessionSteward(saveDirectory: settings.saveDirectory, timeZone: .current)
        state.stewardFindings = await OffMainIO.read { steward.findings() }
    }

    /// 最も新しい未処理セッション1件をフル処理する（タイトル → 自動判定 → パイプライン）。
    /// 完了ごとに再検出するので、残りがあればもう一度押せばよい
    func processNextUnprocessed() {
        guard let finding = state.stewardFindings.first else { return }
        if finding.needsTitle {
            assignTitle(session: finding.session) { [weak self] renamed in
                if finding.needsPipeline {
                    self?.runDefaultPlaybook(session: renamed)
                }
                Task { await self?.refreshSteward() }
            }
        } else if finding.needsPipeline {
            runDefaultPlaybook(session: finding.session)
            Task { [weak self] in
                await self?.refreshSteward()
            }
        }
    }

    /// 過去の記録から「これから聞くセッション」のための事前ブリーフを生成する
    func generateBrief(topic: String?) {
        if case .running = state.generationState { return }
        state.generationState = .running(templateName: "事前ブリーフ")
        let brief = BriefGenerator(
            saveDirectory: settings.saveDirectory,
            timeZone: .current,
            generator: ClaudeCLIGenerator(
                executableURL: settings.claudeExecutableURL,
                arguments: ClaudeCLIGenerator.arguments(model: .sonnet, allowWebResearch: false)
            )
        )
        generationTask = Task { [state] in
            do {
                let url = try await brief.generate(topic: topic)
                state.generationState = .finished(url)
            } catch is CancellationError {
                state.generationState = .idle
            } catch {
                state.generationState = .failed(error.localizedDescription)
            }
        }
    }

    /// Task.cancel → CommandRunner の onCancel → SIGTERM（5秒後 SIGKILL）まで一本でつながる
    func cancel() {
        generationTask?.cancel()
    }

    func openResult(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: Private

    private let state: AppState
    private let settings: AppSettings
    private var generationTask: Task<Void, Never>?

    private func runDefaultPlaybook(session: SessionRef) {
        guard let pipeline else { return }
        pipeline.refresh()
        let playbooks = state.pipelinePlaybooks
        if settings.defaultPlaybookID == AppSettings.autoPlaybookID {
            classifyThenRun(session: session, candidates: playbooks)
        } else if let playbook = playbooks.first(where: { $0.id == settings.defaultPlaybookID }) ?? playbooks.first {
            pipeline.run(playbook: playbook, session: session)
        }
    }

    /// 内容ベースの自動判定（haiku）。判定不能なら実行せず、手動対処を促す表示を出す
    private func classifyThenRun(session: SessionRef, candidates: [Playbook]) {
        state.generationState = .running(templateName: "プレイブック判定")
        let classifier = SessionClassifier(
            saveDirectory: settings.saveDirectory,
            timeZone: .current,
            generator: ClaudeCLIGenerator(
                executableURL: settings.claudeExecutableURL,
                arguments: ClaudeCLIGenerator.arguments(model: .haiku, allowWebResearch: false)
            )
        )
        generationTask = Task { [state, weak self] in
            do {
                let selected = try await classifier.classify(session: session, candidates: candidates)
                state.generationState = .idle
                if let selected {
                    self?.pipeline?.run(playbook: selected, session: session)
                } else {
                    state.generationState = .failed("プレイブックを判定できませんでした。手動で実行してください")
                }
            } catch is CancellationError {
                state.generationState = .idle
            } catch {
                state.generationState = .failed(error.localizedDescription)
            }
        }
    }
}
