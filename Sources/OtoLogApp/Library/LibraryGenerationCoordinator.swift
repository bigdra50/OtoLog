import Foundation
import Observation
import OtoLogCore

// MARK: - LibraryGenerationSettings

/// ライブラリからの実行が設定から読む値。アプリでは AppSettings が満たす。
/// テストで AppSettings を作ると UserDefaults のスイートが残るため、テストは代わりの型を渡す
@MainActor protocol LibraryGenerationSettings: AnyObject {
    var saveDirectory: URL { get }
    var claudeExecutableURL: URL { get }
}

// MARK: - AppSettings + LibraryGenerationSettings

extension AppSettings: LibraryGenerationSettings {}

// MARK: - LibraryGenerationCoordinator

/// ライブラリからの生成の進行を持つ。
///
/// 状態をビューに置くと、セッションを切り替えた時点で表示が失われる
/// （詳細ビューはセッション id で作り直されるため）。
/// 「実行中に別の記録を眺めて、これも生成しておく」を成り立たせるためウィンドウ側に置く。
@MainActor @Observable final class LibraryGenerationCoordinator {
    // MARK: Lifecycle

    /// run は差し替え可能。既定は claude CLI 経由の実生成。
    /// environment は generate を呼ぶたびに1度だけ呼ぶ。
    /// 既定値は run を差し替えるテスト向けで、誤って実生成に渡っても起動に失敗するよう存在しないパスにしている
    init(
        run: @escaping Run,
        runPipeline: RunPipeline? = nil,
        environment: @escaping @MainActor () -> Environment = {
            Environment(
                saveDirectory: URL(fileURLWithPath: "/nonexistent", isDirectory: true),
                claudeExecutableURL: URL(fileURLWithPath: "/nonexistent/claude")
            )
        },
        workLock: SessionWorkLock = .shared
    ) {
        self.run = run
        self.runPipeline = runPipeline
        currentEnvironment = environment
        self.workLock = workLock
    }

    /// コーディネータはアプリの起動時に1度だけ作られる。
    /// 設定はここで写し取らず、実行を始めるたびに読む（ライブラリの一覧も表示のたびに今の保存先を読む）
    convenience init(settings: some LibraryGenerationSettings, workLock: SessionWorkLock = .shared) {
        self.init(run: { session, template, environment in
            let runner = PostProcessRunner(
                directory: environment.saveDirectory,
                timeZone: .current,
                generator: ClaudeCLIGenerator(
                    executableURL: environment.claudeExecutableURL,
                    arguments: ClaudeCLIGenerator.arguments(
                        model: nil,
                        allowWebResearch: template.allowsWebResearch,
                        jsonSchema: template.jsonSchema
                    )
                ),
                workLock: workLock
            )
            return try await runner.run(session: session, template: template)
        }, runPipeline: { session, playbook, only, environment in
            let runner = PipelineRunner(
                saveDirectory: environment.saveDirectory,
                timeZone: .current,
                generatorFactory: { task in
                    let schemas = Dictionary(
                        TemplateStore().loadTemplates().map { ($0.id, $0.jsonSchema) },
                        uniquingKeysWith: { first, _ in first }
                    )
                    return ClaudeCLIGenerator(
                        executableURL: environment.claudeExecutableURL,
                        arguments: ClaudeCLIGenerator.arguments(
                            model: task.model,
                            allowWebResearch: task.allowsWebResearch,
                            jsonSchema: schemas[task.templateID] ?? nil
                        )
                    )
                },
                workLock: workLock
            )
            for await _ in await runner.run(playbook: playbook, session: session, only: only) {}
        }, environment: {
            Environment(saveDirectory: settings.saveDirectory, claudeExecutableURL: settings.claudeExecutableURL)
        }, workLock: workLock)
    }

    // MARK: Internal

    /// 実行の途中で設定が変わっても値がぶれないよう、run・runPipeline は始めに読んだ値を引数で受け取る
    typealias Run = @Sendable (SessionRef, GenerationTemplate, Environment) async throws -> URL
    typealias RunPipeline = @Sendable (SessionRef, Playbook, [String]?, Environment) async -> Void

    /// 1回の実行が設定から使う値。実行の始めに1度だけ読み、途中で設定が変わってもその実行はこの値のまま進める。
    /// 途中で保存先が変わると、同じ実行の読み書きが2つの保存先にまたがる
    struct Environment: Equatable {
        let saveDirectory: URL
        let claudeExecutableURL: URL
    }

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
        // 振り分けに読む meta.json と実行先は同じ保存先でなければならないので、1度だけ読んで両方に使う
        let environment = currentEnvironment()
        if let resolved = pipelineTask(for: template, in: session, under: environment.saveDirectory) {
            await runPlaybook(session: session, playbook: resolved.playbook, only: [resolved.taskID], with: environment)
            return
        }
        await generateAlone(session: session, template: template, with: environment)
    }

    /// プレイブックを走らせる。only を渡すとそのタスクだけを再実行し、
    /// 依存の充足は前回 done の出力を再利用する（補正をやり直さずに下流だけ作り直せる）
    func generate(session: SessionRef, playbook: Playbook, only: [String]? = nil) async {
        await runPlaybook(session: session, playbook: playbook, only: only, with: currentEnvironment())
    }

    // MARK: Private

    private struct Key: Hashable {
        let sessionID: String
        let templateID: String
    }

    private let run: Run
    private let runPipeline: RunPipeline?
    private let currentEnvironment: @MainActor () -> Environment
    private let workLock: SessionWorkLock
    private var running: Set<Key> = []
    private var errors: [String: String] = [:]

    private func runPlaybook(
        session: SessionRef,
        playbook: Playbook,
        only: [String]?,
        with environment: Environment
    ) async {
        guard let runPipeline else { return }
        // 記録中のセッションには走らせない。PipelineRunner も断るが、ライブラリは実行の結果を読まないので、理由はここで出す
        guard await !workLock.isOpen(session, in: environment.saveDirectory) else {
            errors[session.id] = SessionWorkLockError.sessionIsOpen.errorDescription
            return
        }
        let label = only?.first ?? "playbook:\(playbook.id)"
        let key = Key(sessionID: session.id, templateID: label)
        guard !running.contains(key) else { return }
        running.insert(key)
        errors[session.id] = nil
        defer { running.remove(key) }

        await runPipeline(session, playbook, only, environment)
        finished = (
            session: session.id,
            templateID: only?.first ?? playbook.tasks.first?.templateID ?? ""
        )
    }

    private func generateAlone(
        session: SessionRef,
        template: GenerationTemplate,
        with environment: Environment
    ) async {
        let key = Key(sessionID: session.id, templateID: template.id)
        guard !running.contains(key) else { return }
        running.insert(key)
        errors[session.id] = nil
        defer { running.remove(key) }

        do {
            _ = try await run(session, template, environment)
            finished = (session: session.id, templateID: template.id)
        } catch {
            errors[session.id] = error.localizedDescription
        }
    }

    /// このセッションで実行済みのプレイブックに、そのテンプレートのタスクが含まれるか。
    /// 含まれていれば補正の結果を引き継いで再実行できる。saveDirectory は session がある保存先
    private func pipelineTask(
        for template: GenerationTemplate,
        in session: SessionRef,
        under saveDirectory: URL
    ) -> (playbook: Playbook, taskID: String)? {
        guard let playbookID = TranscriptReader(directory: saveDirectory, timeZone: .current)
            .meta(in: session)?.playbookID,
            let playbook = PlaybookStore().loadPlaybooks().first(where: { $0.id == playbookID }),
            let task = playbook.tasks.first(where: { $0.templateID == template.id })
        else { return nil }
        return (playbook, task.id)
    }
}
