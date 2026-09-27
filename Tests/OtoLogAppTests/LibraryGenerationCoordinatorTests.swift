import Foundation
@testable import OtoLogApp
@testable import OtoLogCore
import Testing

/// ライブラリからの生成。
/// 「実行中に別のセッションを眺めて、これも生成しておく」を成り立たせるため、
/// 状態はビューではなくウィンドウ側に置き、複数を同時に走らせられるようにする。
@MainActor struct LibraryGenerationCoordinatorTests {
    // MARK: Internal

    @Test func 実行中は走っていることが分かる() async {
        let gate = Gate()
        let sut = LibraryGenerationCoordinator { _, _, _ in
            await gate.wait()
            return URL(fileURLWithPath: "/tmp/out.md")
        }

        let task = Task { await sut.generate(session: sessionA, template: glossary) }
        while !sut.isRunning(session: sessionA) {
            await Task.yield()
        }

        #expect(sut.isRunning(session: sessionA, templateID: "glossary"))
        #expect(!sut.isRunning(session: sessionB))
        await gate.open()
        await task.value
        #expect(!sut.isRunning(session: sessionA))
    }

    /// 別のセッションは同時に走らせられる
    @Test func 別セッションは並行して走る() async {
        let gate = Gate()
        let sut = LibraryGenerationCoordinator { _, _, _ in
            await gate.wait()
            return URL(fileURLWithPath: "/tmp/out.md")
        }

        let first = Task { await sut.generate(session: sessionA, template: glossary) }
        let second = Task { await sut.generate(session: sessionB, template: minutes) }
        while sut.runningCount < 2 {
            await Task.yield()
        }

        #expect(sut.isRunning(session: sessionA))
        #expect(sut.isRunning(session: sessionB))
        await gate.open()
        _ = await (first.value, second.value)
        #expect(sut.runningCount == 0)
    }

    /// 同じ組み合わせの二重起動は防ぐ。同じファイルを2プロセスで奪い合わせない
    @Test func 同じ組み合わせは二重に起動しない() async {
        let counter = Counter()
        let gate = Gate()
        let sut = LibraryGenerationCoordinator { _, _, _ in
            await counter.increment()
            await gate.wait()
            return URL(fileURLWithPath: "/tmp/out.md")
        }

        let first = Task { await sut.generate(session: sessionA, template: glossary) }
        while !sut.isRunning(session: sessionA) {
            await Task.yield()
        }
        await sut.generate(session: sessionA, template: glossary)

        #expect(await counter.value == 1)
        await gate.open()
        await first.value
    }

    @Test func 失敗は理由が残り再実行できる() async {
        struct Boom: LocalizedError { var errorDescription: String? {
            "失敗した"
        } }
        let sut = LibraryGenerationCoordinator { _, _, _ in throw Boom() }

        await sut.generate(session: sessionA, template: glossary)

        #expect(sut.error(for: sessionA) == "失敗した")
        #expect(!sut.isRunning(session: sessionA))
    }

    /// 成功したら直前の失敗表示は消す
    @Test func 成功すると失敗表示が消える() async {
        struct Boom: Error {}
        let shouldFail = Flag()
        let sut = LibraryGenerationCoordinator { _, _, _ in
            if await shouldFail.value { throw Boom() }
            return URL(fileURLWithPath: "/tmp/out.md")
        }
        await shouldFail.set(true)
        await sut.generate(session: sessionA, template: glossary)
        #expect(sut.error(for: sessionA) != nil)

        await shouldFail.set(false)
        await sut.generate(session: sessionA, template: glossary)

        #expect(sut.error(for: sessionA) == nil)
    }

    /// 通しの再生成も同じ枠で追う。実行中は単発の生成も止める（同じファイルを奪い合わせない）
    @Test func 通しの再生成も実行中として扱う() async {
        let gate = Gate()
        let sut = LibraryGenerationCoordinator(
            run: { _, _, _ in URL(fileURLWithPath: "/tmp/out.md") },
            runPipeline: { _, _, _, _ in await gate.wait() }
        )

        let task = Task { await sut.generate(session: sessionA, playbook: BuiltInPlaybooks.meeting) }
        while !sut.isRunning(session: sessionA) {
            await Task.yield()
        }

        #expect(sut.isRunning(session: sessionA))
        await gate.open()
        await task.value
        #expect(!sut.isRunning(session: sessionA))
    }

    /// パイプラインを渡していなければ何もしない（既定の初期化子は渡す）
    @Test func パイプライン未設定なら実行しない() async {
        let sut = LibraryGenerationCoordinator { _, _, _ in URL(fileURLWithPath: "/tmp/out.md") }

        await sut.generate(session: sessionA, playbook: BuiltInPlaybooks.meeting)

        #expect(!sut.isRunning(session: sessionA))
    }

    /// 補正済みのプレイブックに属するタスクは、単発ではなく only 指定で走らせる。
    /// 単発生成は原文（transcript.jsonl）を読むので、そのままだと補正の結果が捨てられる
    @Test func 補正済みのセッションでは下流だけ再実行する() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogPipe-\(UUID().uuidString)", isDirectory: true)
        let sessionDir = dir.appendingPathComponent("2026-07-31/A")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 会議プレイブックを実行済みのセッションを作る
        var meta = SessionMeta(
            sessionID: UUID(), startedAt: Date(timeIntervalSince1970: 0),
            locale: "ja-JP", source: .system
        )
        meta.playbookID = "meeting"
        try SessionMetaCoder.encode(meta).write(to: sessionDir.appendingPathComponent("meta.json"))

        let recorded = OnlyRecorder()
        let sut = LibraryGenerationCoordinator(
            run: { _, _, _ in URL(fileURLWithPath: "/tmp/out.md") },
            runPipeline: { _, _, only, _ in await recorded.set(only) },
            environment: { Self.environment(saveDirectory: dir) }
        )

        await sut.generate(session: sessionA, template: BuiltInTemplates.minutes)

        // 議事録のタスクだけが指定される（補正はやり直さない）
        #expect(await recorded.value?.count == 1)
    }

    /// プレイブック未実行のセッションは単発で走らせる
    @Test func プレイブック未実行なら単発で走らせる() async {
        let counter = Counter()
        let sut = LibraryGenerationCoordinator(
            run: { _, _, _ in
                await counter.increment()
                return URL(fileURLWithPath: "/tmp/out.md")
            },
            runPipeline: { _, _, _, _ in },
            environment: { Self.environment(saveDirectory: FileManager.default.temporaryDirectory) }
        )

        await sut.generate(session: sessionA, template: BuiltInTemplates.minutes)

        #expect(await counter.value == 1)
    }

    /// 保存先と claude のパスは、実行を始めるたびに設定から読む。
    /// コーディネータはアプリの起動時に1度だけ作られる。作った時点の値を持ち続けると、
    /// 設定を変えた後もライブラリからの実行だけが古い保存先・古い claude で走る
    @Test func 設定を変えると次の単発生成は新しい保存先とclaudeを使う() async {
        let settings = SettingsStub(oldEnvironment)
        let recorded = EnvironmentRecorder()
        let sut = LibraryGenerationCoordinator(
            run: { _, _, environment in
                await recorded.append(environment)
                return URL(fileURLWithPath: "/tmp/out.md")
            },
            environment: { settings.value }
        )

        await sut.generate(session: sessionA, template: glossary)
        settings.value = newEnvironment
        await sut.generate(session: sessionA, template: glossary)

        #expect(await recorded.values == [oldEnvironment, newEnvironment])
    }

    @Test func 設定を変えると次のプレイブック実行は新しい保存先とclaudeを使う() async {
        let settings = SettingsStub(oldEnvironment)
        let recorded = EnvironmentRecorder()
        let sut = LibraryGenerationCoordinator(
            run: { _, _, _ in URL(fileURLWithPath: "/tmp/out.md") },
            runPipeline: { _, _, _, environment in await recorded.append(environment) },
            environment: { settings.value }
        )

        await sut.generate(session: sessionA, playbook: BuiltInPlaybooks.meeting)
        settings.value = newEnvironment
        await sut.generate(session: sessionA, playbook: BuiltInPlaybooks.meeting)

        #expect(await recorded.values == [oldEnvironment, newEnvironment])
    }

    /// 実行中に設定を変えても、その実行は始めた時点の保存先と claude のまま最後まで進む。
    /// 途中で保存先が変わると、同じ実行の読み書きが2つの保存先にまたがる
    @Test func 実行中に設定を変えてもその実行は始めた時点の値で進む() async {
        let settings = SettingsStub(oldEnvironment)
        let gate = Gate()
        let recorded = EnvironmentRecorder()
        let sut = LibraryGenerationCoordinator(
            run: { _, _, environment in
                await gate.wait()
                await recorded.append(environment)
                return URL(fileURLWithPath: "/tmp/out.md")
            },
            environment: { settings.value }
        )

        let task = Task { await sut.generate(session: sessionA, template: glossary) }
        while !sut.isRunning(session: sessionA) {
            await Task.yield()
        }
        settings.value = newEnvironment
        await gate.open()
        await task.value

        #expect(await recorded.values == [oldEnvironment])
    }

    /// 振り分けに使う meta.json は、実行を始めた時点の保存先から読む。
    /// 起動時の保存先を見続けると、新しい保存先で補正済みのセッションが単発で走り、補正の結果が捨てられる
    @Test func 保存先を変えると新しい保存先のmetaで振り分ける() async throws {
        try await SessionFixture.withTempDir { root in
            let oldDirectory = root.appendingPathComponent("old", isDirectory: true)
            let newDirectory = root.appendingPathComponent("new", isDirectory: true)
            // 会議プレイブックを実行済みのセッションは、新しい保存先にだけある
            let session = try SessionFixture.make(
                in: newDirectory, name: "2026-07-31/1300", texts: ["こんにちは"], playbookID: "meeting"
            )
            let settings = SettingsStub(Self.environment(saveDirectory: oldDirectory))
            let recorded = OnlyRecorder()
            let sut = LibraryGenerationCoordinator(
                run: { _, _, _ in URL(fileURLWithPath: "/tmp/out.md") },
                runPipeline: { _, _, only, _ in await recorded.set(only) },
                environment: { settings.value }
            )

            settings.value = Self.environment(saveDirectory: newDirectory)
            await sut.generate(session: session, template: BuiltInTemplates.minutes)

            #expect(await recorded.value?.count == 1)
        }
    }

    /// 振り分けと実行は、実行の始めに読んだ同じ値を使う。
    /// 読むたびに値が変わっても、meta.json を読んだ保存先とパイプラインを走らせる保存先は分かれない
    @Test func 振り分けと実行は同じ時点の設定を使う() async throws {
        try await SessionFixture.withTempDir { root in
            let oldDirectory = root.appendingPathComponent("old", isDirectory: true)
            let newDirectory = root.appendingPathComponent("new", isDirectory: true)
            let session = try SessionFixture.make(
                in: oldDirectory, name: "2026-07-31/1300", texts: ["こんにちは"], playbookID: "meeting"
            )
            // 1回読まれた直後に設定が変わる状況を作る
            let reads = SettingsStub(Self.environment(saveDirectory: oldDirectory))
            let recorded = EnvironmentRecorder()
            let sut = LibraryGenerationCoordinator(
                run: { _, _, environment in
                    await recorded.append(environment)
                    return URL(fileURLWithPath: "/tmp/out.md")
                },
                runPipeline: { _, _, _, environment in await recorded.append(environment) },
                environment: {
                    let current = reads.value
                    reads.value = Self.environment(saveDirectory: newDirectory)
                    return current
                }
            )

            await sut.generate(session: session, template: BuiltInTemplates.minutes)

            #expect(await recorded.values == [Self.environment(saveDirectory: oldDirectory)])
        }
    }

    // MARK: Private

    private actor Gate {
        // MARK: Internal

        func wait() async {
            while !isOpen {
                await Task.yield()
            }
        }

        func open() {
            isOpen = true
        }

        // MARK: Private

        private var isOpen = false
    }

    private actor OnlyRecorder {
        var value: [String]?

        func set(_ newValue: [String]?) {
            value = newValue
        }
    }

    private actor Counter {
        var value = 0

        func increment() {
            value += 1
        }
    }

    private actor Flag {
        var value = false

        func set(_ newValue: Bool) {
            value = newValue
        }
    }

    /// 設定の代わり。AppSettings は UserDefaults のスイートを残すため、値を直接差し替える
    @MainActor private final class SettingsStub {
        // MARK: Lifecycle

        init(_ value: LibraryGenerationCoordinator.Environment) {
            self.value = value
        }

        // MARK: Internal

        var value: LibraryGenerationCoordinator.Environment
    }

    private actor EnvironmentRecorder {
        var values: [LibraryGenerationCoordinator.Environment] = []

        func append(_ environment: LibraryGenerationCoordinator.Environment) {
            values.append(environment)
        }
    }

    private var oldEnvironment: LibraryGenerationCoordinator.Environment {
        LibraryGenerationCoordinator.Environment(
            saveDirectory: URL(fileURLWithPath: "/tmp/otolog-old", isDirectory: true),
            claudeExecutableURL: URL(fileURLWithPath: "/opt/old/bin/claude")
        )
    }

    private var newEnvironment: LibraryGenerationCoordinator.Environment {
        LibraryGenerationCoordinator.Environment(
            saveDirectory: URL(fileURLWithPath: "/tmp/otolog-new", isDirectory: true),
            claudeExecutableURL: URL(fileURLWithPath: "/opt/new/bin/claude")
        )
    }

    private var sessionA: SessionRef {
        SessionRef(directoryName: "2026-07-31/A", title: "A", startedAt: Date(timeIntervalSince1970: 0))
    }

    private var sessionB: SessionRef {
        SessionRef(directoryName: "2026-07-31/B", title: "B", startedAt: Date(timeIntervalSince1970: 0))
    }

    private var glossary: GenerationTemplate {
        BuiltInTemplates.glossary
    }

    private var minutes: GenerationTemplate {
        BuiltInTemplates.minutes
    }

    private static func environment(saveDirectory: URL) -> LibraryGenerationCoordinator.Environment {
        LibraryGenerationCoordinator.Environment(
            saveDirectory: saveDirectory,
            claudeExecutableURL: URL(fileURLWithPath: "/usr/local/bin/claude")
        )
    }
}
