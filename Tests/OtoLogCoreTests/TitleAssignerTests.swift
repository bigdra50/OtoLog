import Foundation
@testable import OtoLogCore
import Testing

struct TitleAssignerTests {
    // MARK: Internal

    let jst = TimeZone(identifier: "Asia/Tokyo")!

    @Test func assignsTitleRenamingDirectoryUpdatingMetaAndMarkdownHeader() async throws {
        try await withTempDir { root in
            let ref = try makeSession(in: root, name: "2026-07-29/1300", texts: ["ボクセル技術の講演です"])
            let generator = FakeTextGenerator(result: "ボクセル技術講演")
            let assigner = TitleAssigner(
                saveDirectory: root, timeZone: jst, generator: generator, correctionStore: nil
            )

            let renamed = try await assigner.assignTitle(to: ref)

            #expect(renamed.directoryName == "2026-07-29/ボクセル技術講演")
            #expect(renamed.title == "ボクセル技術講演")
            let newDir = root.appendingPathComponent("2026-07-29/ボクセル技術講演")
            #expect(FileManager.default.fileExists(atPath: newDir.path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-07-29/1300").path))

            let meta = try SessionMetaCoder.decode(Data(contentsOf: newDir.appendingPathComponent("meta.json")))
            #expect(meta.title == "ボクセル技術講演")

            let md = try String(contentsOf: newDir.appendingPathComponent("transcript.md"), encoding: .utf8)
            #expect(md.hasPrefix("# ボクセル技術講演\n"))
            #expect(generator.receivedPrompts.first?.contains("ボクセル技術の講演です") == true)
        }
    }

    /// 同じ日に同名タイトルがあれば連番を付ける（日付フォルダ内の重複回避）
    @Test func appendsSuffixWhenSameTitleExistsOnSameDate() async throws {
        try await withTempDir { root in
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("2026-07-29/定例会議"), withIntermediateDirectories: true
            )
            let ref = try makeSession(in: root, name: "2026-07-29/1300", texts: ["二回目の定例"])
            let assigner = TitleAssigner(
                saveDirectory: root, timeZone: jst, generator: FakeTextGenerator(result: "定例会議"),
                correctionStore: nil
            )

            let renamed = try await assigner.assignTitle(to: ref)

            #expect(renamed.directoryName == "2026-07-29/定例会議-2")
        }
    }

    /// 旧フラット構造のセッションはタイトル付与と同時に日付フォルダ階層へ移る
    @Test func migratesFlatSessionIntoDateFolderOnAssign() async throws {
        try await withTempDir { root in
            let ref = try makeSession(in: root, name: "2026-07-29_1300_古いタイトル", texts: ["本文"])
            let assigner = TitleAssigner(
                saveDirectory: root, timeZone: jst, generator: FakeTextGenerator(result: "新しいタイトル"),
                correctionStore: nil
            )

            let renamed = try await assigner.assignTitle(to: ref)

            #expect(renamed.directoryName == "2026-07-29/新しいタイトル")
            #expect(!FileManager.default.fileExists(
                atPath: root.appendingPathComponent("2026-07-29_1300_古いタイトル").path
            ))
        }
    }

    /// モデルの拒否文・説明文（句点を含む文章や長文）はタイトルに採用しない。
    /// 「申し訳ございませんが、…1語のみのため…」がディレクトリ名になった実害の再発防止
    @Test func rejectsSentenceLikeOrOverlongGeneratedTitle() async throws {
        try await withTempDir { root in
            let sentence = "申し訳ございませんが、提供いただいたログが「はい」という1語のみのため、内容を推測できません。"
            for bad in [sentence, String(repeating: "長", count: 31)] {
                let ref = try makeSession(in: root, name: "2026-07-29/1300", texts: ["はい"])
                let assigner = TitleAssigner(
                    saveDirectory: root, timeZone: jst, generator: FakeTextGenerator(result: bad),
                    correctionStore: nil
                )
                await #expect(throws: TitleAssignerError.self) {
                    _ = try await assigner.assignTitle(to: ref)
                }
                try FileManager.default.removeItem(at: root.appendingPathComponent("2026-07-29"))
            }
        }
    }

    @Test func throwsWhenGeneratedTitleSanitizesToEmpty() async throws {
        try await withTempDir { root in
            let ref = try makeSession(in: root, name: "2026-07-29/1300", texts: ["本文"])
            let assigner = TitleAssigner(
                saveDirectory: root, timeZone: jst, generator: FakeTextGenerator(result: " /// "),
                correctionStore: nil
            )
            await #expect(throws: TitleAssignerError.self) {
                _ = try await assigner.assignTitle(to: ref)
            }
        }
    }

    /// md が無い（全 volatile 等）セッションでもタイトル付与は成立する
    @Test func succeedsWithoutMarkdownFile() async throws {
        try await withTempDir { root in
            let ref = try makeSession(
                in: root, name: "2026-07-29/1300", texts: ["本文"], writeMarkdown: false
            )
            let assigner = TitleAssigner(
                saveDirectory: root, timeZone: jst, generator: FakeTextGenerator(result: "タイトル"),
                correctionStore: nil
            )
            let renamed = try await assigner.assignTitle(to: ref)
            #expect(renamed.title == "タイトル")
        }
    }

    // MARK: 記録中と、同じ記録のほかの作業

    /// 記録中の記録には付けない。生成を呼ぶ前に断り、ディレクトリも動かさない
    @Test func refusesAnOpenSessionBeforeGenerating() async throws {
        try await withTempDir { root in
            let ref = try makeSession(in: root, name: "2026-07-29/1300", texts: ["本文"])
            let lock = SessionWorkLock()
            _ = await lock.open(ref, in: root)
            let generator = FakeTextGenerator(result: "定例会議")
            let assigner = TitleAssigner(
                saveDirectory: root, timeZone: jst, generator: generator, correctionStore: nil, workLock: lock
            )

            await #expect(throws: SessionWorkLockError.sessionIsOpen) {
                _ = try await assigner.assignTitle(to: ref)
            }

            #expect(generator.receivedPrompts.isEmpty)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-07-29/1300").path))
        }
    }

    /// 記録中にタイトルを付けようとしても、発話は1つのディレクトリにまとまり、閉じた記録に終わりが残る。
    /// 移してしまうと、次の追記が元の名前でディレクトリを作り直して記録が2つに割れる
    @Test func recordingSessionStaysInOneDirectoryWhenTitlingIsAttempted() async throws {
        try await withTempDir { root in
            let lock = SessionWorkLock()
            let store = SessionFileStore(directory: root, timeZone: jst, workLock: lock)
            let startedAt = Date(timeIntervalSince1970: 1_785_297_600)
            try await store.begin(context: TranscriptionContext(
                locale: "ja-JP", source: .system, sessionID: UUID(), sessionStartedAt: startedAt
            ))
            try await store.append(TestFixtures.segment(text: "前半の発言", finalizedAt: startedAt + 60))
            // ポップオーバーは記録中の記録も一覧の先頭（既定の選択）に出す
            let live = try #require(TranscriptReader(directory: root, timeZone: jst).availableSessions().first)
            let assigner = TitleAssigner(
                saveDirectory: root, timeZone: jst, generator: FakeTextGenerator(result: "定例会議"),
                correctionStore: nil, workLock: lock
            )

            await #expect(throws: SessionWorkLockError.sessionIsOpen) {
                _ = try await assigner.assignTitle(to: live)
            }
            try await store.append(TestFixtures.segment(text: "後半の発言", finalizedAt: startedAt + 120))
            _ = try await store.finalize(endedAt: startedAt + 180, reason: .stopped)

            let reader = TranscriptReader(directory: root, timeZone: jst)
            let sessions = reader.availableSessions()
            #expect(sessions.map(\.directoryName) == ["2026-07-29/1300"])
            let only = try #require(sessions.first)
            #expect(try reader.segments(in: only).map(\.text) == ["前半の発言", "後半の発言"])
            #expect(reader.meta(in: only)?.endedAt != nil)
        }
    }

    /// 同じ記録で生成が書いている間は移さず、終わるのを待ってから移す。移すと書き途中の生成が保存先を失う
    @Test func waitsForRunningWorkBeforeMovingTheDirectory() async throws {
        try await withTempDir { root in
            let ref = try makeSession(in: root, name: "2026-07-29/1300", texts: ["本文"])
            let lock = SessionWorkLock()
            let generation = try await lock.acquire(.generation, for: ref, in: root)
            let assigner = TitleAssigner(
                saveDirectory: root, timeZone: jst, generator: FakeTextGenerator(result: "定例会議"),
                correctionStore: nil, workLock: lock
            )

            let titling = Task { try await assigner.assignTitle(to: ref) }
            #expect(await eventually { await lock.waitingCount(for: ref, in: root) == 1 })
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-07-29/1300").path))
            await lock.release(generation)

            #expect(try await titling.value.directoryName == "2026-07-29/定例会議")
        }
    }

    /// 移した後に古い参照から来た作業は、移った先を受け持つ
    @Test func handsTheNewPlaceToLaterWork() async throws {
        try await withTempDir { root in
            let ref = try makeSession(in: root, name: "2026-07-29/1300", texts: ["本文"])
            let lock = SessionWorkLock()
            let assigner = TitleAssigner(
                saveDirectory: root, timeZone: jst, generator: FakeTextGenerator(result: "定例会議"),
                correctionStore: nil, workLock: lock
            )
            let renamed = try await assigner.assignTitle(to: ref)

            let lease = try await lock.acquire(.generation, for: ref, in: root)

            #expect(lease.session == renamed)
        }
    }

    // MARK: Private

    private func makeSession(
        in root: URL, name: String, texts: [String], writeMarkdown: Bool = true
    ) throws -> SessionRef {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let startedAt = Date(timeIntervalSince1970: 1_785_297_600)
        let meta = SessionMeta(sessionID: UUID(), startedAt: startedAt, locale: "ja-JP", source: .system)
        try SessionMetaCoder.encode(meta).write(to: dir.appendingPathComponent("meta.json"))
        let lines = try texts.map { try JSONLCoder.encodeLine(TestFixtures.segment(text: $0)) }
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8
        )
        if writeMarkdown {
            let md = "# 2026-07-29 13:00\n\n" + texts.map { "- **13:00:00** \($0)\n" }.joined()
            try md.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        }
        return SessionRef(directoryName: name, title: nil, startedAt: startedAt)
    }

    private func withTempDir(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }
}
