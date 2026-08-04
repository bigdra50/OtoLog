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
        let sut = LibraryGenerationCoordinator { _, _ in
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
        let sut = LibraryGenerationCoordinator { _, _ in
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
        let sut = LibraryGenerationCoordinator { _, _ in
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
        let sut = LibraryGenerationCoordinator { _, _ in throw Boom() }

        await sut.generate(session: sessionA, template: glossary)

        #expect(sut.error(for: sessionA) == "失敗した")
        #expect(!sut.isRunning(session: sessionA))
    }

    /// 成功したら直前の失敗表示は消す
    @Test func 成功すると失敗表示が消える() async {
        struct Boom: Error {}
        let shouldFail = Flag()
        let sut = LibraryGenerationCoordinator { _, _ in
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
            run: { _, _ in URL(fileURLWithPath: "/tmp/out.md") },
            runPipeline: { _, _, _ in await gate.wait() }
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
        let sut = LibraryGenerationCoordinator { _, _ in URL(fileURLWithPath: "/tmp/out.md") }

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
            run: { _, _ in URL(fileURLWithPath: "/tmp/out.md") },
            runPipeline: { _, _, only in await recorded.set(only) },
            saveDirectory: dir
        )

        await sut.generate(session: sessionA, template: BuiltInTemplates.minutes)

        // 議事録のタスクだけが指定される（補正はやり直さない）
        #expect(await recorded.value?.count == 1)
    }

    /// プレイブック未実行のセッションは単発で走らせる
    @Test func プレイブック未実行なら単発で走らせる() async {
        let counter = Counter()
        let sut = LibraryGenerationCoordinator(
            run: { _, _ in
                await counter.increment()
                return URL(fileURLWithPath: "/tmp/out.md")
            },
            runPipeline: { _, _, _ in },
            saveDirectory: FileManager.default.temporaryDirectory
        )

        await sut.generate(session: sessionA, template: BuiltInTemplates.minutes)

        #expect(await counter.value == 1)
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
}
