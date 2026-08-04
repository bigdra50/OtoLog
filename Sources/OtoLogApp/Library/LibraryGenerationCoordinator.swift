import Foundation
import Observation
import OtoLogCore

/// ライブラリからの生成の進行を持つ。
///
/// 状態をビューに置くと、セッションを切り替えた時点で表示が失われる
/// （詳細ビューはセッション id で作り直されるため）。
/// 「実行中に別の記録を眺めて、これも生成しておく」を成り立たせるためウィンドウ側に置く。
@MainActor @Observable final class LibraryGenerationCoordinator {
    // MARK: Lifecycle

    /// run は差し替え可能。既定は claude CLI 経由の実生成
    init(run: @escaping Run, runPipeline: RunPipeline? = nil, saveDirectory: URL = URL(fileURLWithPath: "/")) {
        self.run = run
        self.runPipeline = runPipeline
        self.saveDirectory = saveDirectory
    }

    convenience init(settings: AppSettings) {
        // クロージャは MainActor の外で走るので、設定値はここで写し取る
        let directory = settings.saveDirectory
        let executableURL = settings.claudeExecutableURL
        let saveDirectory = settings.saveDirectory
        self.init(run: { session, template in
            let runner = PostProcessRunner(
                directory: directory,
                timeZone: .current,
                generator: ClaudeCLIGenerator(
                    executableURL: executableURL,
                    arguments: ClaudeCLIGenerator.arguments(
                        model: nil,
                        allowWebResearch: template.allowsWebResearch,
                        jsonSchema: template.jsonSchema
                    )
                )
            )
            return try await runner.run(session: session, template: template)
        }, runPipeline: { session, playbook, only in
            let runner = PipelineRunner(
                saveDirectory: saveDirectory,
                timeZone: .current,
                generatorFactory: { task in
                    let schemas = Dictionary(
                        TemplateStore().loadTemplates().map { ($0.id, $0.jsonSchema) },
                        uniquingKeysWith: { first, _ in first }
                    )
                    return ClaudeCLIGenerator(
                        executableURL: executableURL,
                        arguments: ClaudeCLIGenerator.arguments(
                            model: task.model,
                            allowWebResearch: task.allowsWebResearch,
                            jsonSchema: schemas[task.templateID] ?? nil
                        )
                    )
                }
            )
            for await _ in await runner.run(playbook: playbook, session: session, only: only) {}
        }, saveDirectory: saveDirectory)
    }

    // MARK: Internal

    typealias Run = @Sendable (SessionRef, GenerationTemplate) async throws -> URL
    typealias RunPipeline = @Sendable (SessionRef, Playbook, [String]?) async -> Void

    /// 実行中の1件（アクティビティ表示用）。label はテンプレート id か "playbook:<id>"
    struct RunningGeneration: Identifiable, Equatable {
        let sessionID: String
        let label: String

        var id: String {
            "\(sessionID)/\(label)"
        }
    }

    /// 生成が終わったセッション。開いている画面の再読み込みに使う
    var finished: (session: String, templateID: String)?

    var runningCount: Int {
        running.count
    }

    var runningEntries: [RunningGeneration] {
        running
            .map { RunningGeneration(sessionID: $0.sessionID, label: $0.templateID) }
            .sorted { $0.id < $1.id }
    }

    func isRunning(session: SessionRef) -> Bool {
        running.contains { $0.sessionID == session.id }
    }

    func isRunning(session: SessionRef, templateID: String) -> Bool {
        running.contains(Key(sessionID: session.id, templateID: templateID))
    }

    func runningTemplateID(for session: SessionRef) -> String? {
        running.first { $0.sessionID == session.id }?.templateID
    }

    func error(for session: SessionRef) -> String? {
        errors[session.id]
    }

    /// 同じセッション・同じテンプレートの二重起動は無視する（同じファイルを奪い合わせない）。
    ///
    /// 補正済みのプレイブックに属するタスクなら、単発ではなく `only` 指定で走らせる。
    /// 単発生成は transcript.jsonl（原文）を読むため、そのままだと補正の結果が捨てられる
    func generate(session: SessionRef, template: GenerationTemplate) async {
        if let resolved = pipelineTask(for: template, in: session) {
            await generate(session: session, playbook: resolved.playbook, only: [resolved.taskID])
            return
        }
        await generateAlone(session: session, template: template)
    }

    /// プレイブックを走らせる。only を渡すとそのタスクだけを再実行し、
    /// 依存の充足は前回 done の出力を再利用する（補正をやり直さずに下流だけ作り直せる）
    func generate(session: SessionRef, playbook: Playbook, only: [String]? = nil) async {
        guard let runPipeline else { return }
        let label = only?.first ?? "playbook:\(playbook.id)"
        let key = Key(sessionID: session.id, templateID: label)
        guard !running.contains(key) else { return }
        running.insert(key)
        errors[session.id] = nil
        defer { running.remove(key) }

        await runPipeline(session, playbook, only)
        finished = (
            session: session.id,
            templateID: only?.first ?? playbook.tasks.first?.templateID ?? ""
        )
    }

    // MARK: Private

    private struct Key: Hashable {
        let sessionID: String
        let templateID: String
    }

    private let run: Run
    private let runPipeline: RunPipeline?
    private let saveDirectory: URL
    private var running: Set<Key> = []
    private var errors: [String: String] = [:]

    private func generateAlone(session: SessionRef, template: GenerationTemplate) async {
        let key = Key(sessionID: session.id, templateID: template.id)
        guard !running.contains(key) else { return }
        running.insert(key)
        errors[session.id] = nil
        defer { running.remove(key) }

        do {
            _ = try await run(session, template)
            finished = (session: session.id, templateID: template.id)
        } catch {
            errors[session.id] = error.localizedDescription
        }
    }

    /// このセッションで実行済みのプレイブックに、そのテンプレートのタスクが含まれるか。
    /// 含まれていれば補正の結果を引き継いで再実行できる
    private func pipelineTask(
        for template: GenerationTemplate,
        in session: SessionRef
    ) -> (playbook: Playbook, taskID: String)? {
        guard let playbookID = meta(for: session)?.playbookID,
              let playbook = PlaybookStore().loadPlaybooks().first(where: { $0.id == playbookID }),
              let task = playbook.tasks.first(where: { $0.templateID == template.id })
        else { return nil }
        return (playbook, task.id)
    }

    private func meta(for session: SessionRef) -> SessionMeta? {
        TranscriptReader(directory: saveDirectory, timeZone: .current).meta(in: session)
    }
}
