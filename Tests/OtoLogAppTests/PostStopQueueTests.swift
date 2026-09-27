import Foundation
@testable import OtoLogApp
@testable import OtoLogCore
import Testing

/// 停止後の自動処理（タイトル生成 → プレイブック）は、生成やパイプラインが走っている間も飛ばさず、
/// 終わるのを待ってから走らせる。飛ばすと何も表示されないまま、タイトルもプレイブックも付かない記録が残る
@MainActor struct PostStopQueueTests {
    // MARK: Internal

    /// 生成を実行している間に止めた記録にも、その生成が終わってからタイトルを付ける
    @Test func 生成の実行中に止めた記録にもタイトルを付ける() async throws {
        try await SessionFixture.withTempDir { root in
            let busy = try SessionFixture.make(in: root, name: "2026-07-29/1300", texts: ["前の記録"])
            let stopped = try SessionFixture.make(in: root, name: "2026-07-29/1400", texts: ["止めた記録"])
            let gate = root.appendingPathComponent("gate")
            let (state, settings) = try makeStateAndSettings(saveDirectory: root, gate: gate)
            settings.postStopAction = .title
            let generation = GenerationCoordinator(state: state, settings: settings, workLock: SessionWorkLock())
            generation.generate(session: busy, template: BuiltInTemplates.minutes)

            let postStop = Task { await generation.runPostStopAction(for: stopped, in: root) }
            try await Task.sleep(for: .milliseconds(300))
            #expect(state.generationState == .running(templateName: BuiltInTemplates.minutes.displayName))
            try Data().write(to: gate)
            await postStop.value

            #expect(await eventually(timeout: .seconds(10)) { Self.exists("2026-07-29/定例会議", under: root) })
            #expect(await eventually(timeout: .seconds(10)) { await MainActor.run { !Self.isRunning(state) } })
        }
    }

    /// パイプラインを実行している間に止めた記録にも、その実行が終わってからプレイブックを走らせる
    @Test func パイプラインの実行中に止めた記録にもプレイブックを走らせる() async throws {
        try await SessionFixture.withTempDir { root in
            let busy = try SessionFixture.make(in: root, name: "2026-07-29/1300", texts: ["前の記録"])
            let stopped = try SessionFixture.make(in: root, name: "2026-07-29/1400", texts: ["止めた記録"])
            let gate = root.appendingPathComponent("gate")
            let (state, settings) = try makeStateAndSettings(saveDirectory: root, gate: gate)
            settings.postStopAction = .titleAndPipeline
            settings.defaultPlaybookID = "meeting"
            let generation = GenerationCoordinator(state: state, settings: settings, workLock: SessionWorkLock())
            let pipeline = PipelineCoordinator(state: state, settings: settings)
            generation.pipeline = pipeline
            pipeline.run(playbook: BuiltInPlaybooks.meeting, session: busy)

            await generation.runPostStopAction(for: stopped, in: root)
            // タイトルは待たずに付く（生成の枠は空いている）。プレイブックは実行中のパイプラインが終わるまで待つ
            #expect(await eventually(timeout: .seconds(10)) { Self.exists("2026-07-29/定例会議", under: root) })
            try await Task.sleep(for: .milliseconds(300))
            #expect(Self.playbookID(of: "2026-07-29/定例会議", under: root) == nil)
            try Data().write(to: gate)

            #expect(await eventually(timeout: .seconds(10)) {
                Self.playbookID(of: "2026-07-29/定例会議", under: root) == "meeting"
            })
            #expect(await eventually(timeout: .seconds(20)) { await MainActor.run { !state.pipelineRunning } })
        }
    }

    /// プレイブックの判定は、利用者の生成が終わるのを待ってから始める。
    /// 待たずに始めると、実行中の生成の表示と取り消し先を判定が奪い、取り消しボタンが判定のほうを止める
    @Test func 判定はほかの生成が終わるのを待ってから始める() async throws {
        try await SessionFixture.withTempDir { root in
            let busy = try SessionFixture.make(in: root, name: "2026-07-29/1300", texts: ["前の記録"])
            let titled = try SessionFixture.make(in: root, name: "2026-07-29/1400", texts: ["講演の記録"], title: "講演")
            let gate = root.appendingPathComponent("gate")
            let (state, settings) = try makeStateAndSettings(saveDirectory: root, gate: gate)
            settings.defaultPlaybookID = AppSettings.autoPlaybookID
            let generation = GenerationCoordinator(state: state, settings: settings, workLock: SessionWorkLock())
            let pipeline = PipelineCoordinator(state: state, settings: settings)
            generation.pipeline = pipeline
            generation.generate(session: busy, template: BuiltInTemplates.minutes)
            state.stewardFindings = [StewardFinding(session: titled, needsTitle: false, needsPipeline: true)]

            generation.processNextUnprocessed()
            try await Task.sleep(for: .milliseconds(300))

            #expect(state.generationState == .running(templateName: BuiltInTemplates.minutes.displayName))
            try Data().write(to: gate)
            // 判定の答えは偽の claude が返す lecture
            #expect(await eventually(timeout: .seconds(10)) {
                Self.playbookID(of: "2026-07-29/1400", under: root) == "lecture"
            })
            #expect(await eventually(timeout: .seconds(20)) {
                await MainActor.run { !state.pipelineRunning && !Self.isRunning(state) }
            })
        }
    }

    // MARK: Private

    private static func isRunning(_ state: AppState) -> Bool {
        if case .running = state.generationState { return true }
        return false
    }

    private nonisolated static func exists(_ name: String, under root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    private nonisolated static func playbookID(of name: String, under root: URL) -> String? {
        let url = root.appendingPathComponent(name).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? SessionMetaCoder.decode(data).playbookID
    }

    /// 偽の claude を置いた設定。タイトル生成とプレイブックの判定にはすぐ答え、
    /// それ以外の生成（単発生成とパイプラインのタスク）は gate のファイルができるまで答えない
    private func makeStateAndSettings(saveDirectory: URL, gate: URL) throws -> (AppState, AppSettings) {
        let defaults = UserDefaults(suiteName: "OtoLogAppTests.post-stop-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.saveDirectoryPath = saveDirectory.path
        let bin = saveDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let claude = bin.appendingPathComponent("claude")
        try """
        #!/bin/sh
        input=$(cat)
        case "$input" in
          *短いタイトル*) printf '定例会議' ;;
          *分類を1つ選んで*) printf 'lecture' ;;
          *) while [ ! -f '\(gate.path)' ]; do sleep 0.05; done; printf '生成した本文' ;;
        esac

        """.write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        settings.claudeExecutablePath = claude.path
        return (AppState(), settings)
    }
}
