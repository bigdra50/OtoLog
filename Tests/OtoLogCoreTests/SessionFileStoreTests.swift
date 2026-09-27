import Foundation
@testable import OtoLogCore
import Testing

struct SessionFileStoreTests {
    // MARK: Internal

    let jst = TimeZone(identifier: "Asia/Tokyo")!

    /// 1785297600 = 2026-07-29 13:00 JST
    let context = TranscriptionContext(
        locale: "ja-JP",
        source: .system,
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        sessionStartedAt: Date(timeIntervalSince1970: 1_785_297_600)
    )

    @Test func beginCreatesSessionDirectoryWithMeta() async throws {
        try await withTempDir { dir in
            let store = SessionFileStore(directory: dir, timeZone: jst)
            try await store.begin(context: context)

            let sessionDir = dir.appendingPathComponent("2026-07-29/1300")
            #expect(FileManager.default.fileExists(atPath: sessionDir.path))
            let meta = try SessionMetaCoder.decode(
                Data(contentsOf: sessionDir.appendingPathComponent("meta.json"))
            )
            #expect(meta.sessionID == context.sessionID)
            #expect(meta.title == nil)
            #expect(meta.endedAt == nil)
        }
    }

    /// 同じ分に複数セッションを開始しても上書きしない
    @Test func beginResolvesNameCollisionWithSuffix() async throws {
        try await withTempDir { dir in
            let store = SessionFileStore(directory: dir, timeZone: jst)
            try await store.begin(context: context)
            _ = try await store.finalize(endedAt: Date(timeIntervalSince1970: 1_785_297_660), reason: .stopped)
            try await store.begin(context: context)

            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("2026-07-29/1300").path))
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("2026-07-29/1300-2").path))
        }
    }

    @Test func appendWritesJSONLAndMarkdownWithSessionHeader() async throws {
        try await withTempDir { dir in
            let store = SessionFileStore(directory: dir, timeZone: jst)
            try await store.begin(context: context)
            try await store.append(TestFixtures.segment(text: "こんにちは"))

            let sessionDir = dir.appendingPathComponent("2026-07-29/1300")
            let md = try String(contentsOf: sessionDir.appendingPathComponent("transcript.md"), encoding: .utf8)
            #expect(md == "# 2026-07-29 13:00\n\n- **13:00:00** こんにちは\n")
            let jsonl = try String(contentsOf: sessionDir.appendingPathComponent("transcript.jsonl"), encoding: .utf8)
            #expect(jsonl.hasSuffix("\n"))
            #expect(jsonl.contains("こんにちは"))
        }
    }

    /// セッション単位保存では日を跨いでもファイルを分けない（日次ロールオーバーの廃止）
    @Test func appendKeepsSingleFileAcrossMidnight() async throws {
        try await withTempDir { dir in
            let store = SessionFileStore(directory: dir, timeZone: jst)
            try await store.begin(context: context)
            // 23:59 JST と翌 00:01 JST
            try await store.append(TestFixtures.segment(
                text: "前日", finalizedAt: Date(timeIntervalSince1970: 1_785_337_140)
            ))
            try await store.append(TestFixtures.segment(
                text: "翌日", finalizedAt: Date(timeIntervalSince1970: 1_785_337_260)
            ))

            let sessionDir = dir.appendingPathComponent("2026-07-29/1300")
            let md = try String(contentsOf: sessionDir.appendingPathComponent("transcript.md"), encoding: .utf8)
            #expect(md.contains("前日"))
            #expect(md.contains("翌日"))
            // 日を跨いでも新しい日付フォルダやセッションは作られない
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["2026-07-29"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("2026-07-29").path)
                == ["1300"])
        }
    }

    @Test func appendWithoutBeginThrows() async throws {
        try await withTempDir { dir in
            let store = SessionFileStore(directory: dir, timeZone: jst)
            await #expect(throws: SessionFileStoreError.self) {
                try await store.append(TestFixtures.segment(text: "宙に浮く"))
            }
        }
    }

    @Test func whitespaceOnlyTextSkipsMarkdownButKeepsJSONL() async throws {
        try await withTempDir { dir in
            let store = SessionFileStore(directory: dir, timeZone: jst)
            try await store.begin(context: context)
            try await store.append(TestFixtures.segment(text: "   \n  "))

            let sessionDir = dir.appendingPathComponent("2026-07-29/1300")
            #expect(!FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("transcript.md").path))
            #expect(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("transcript.jsonl").path))
        }
    }

    @Test func finalizeUpdatesEndedAtAndReturnsRef() async throws {
        try await withTempDir { dir in
            let store = SessionFileStore(directory: dir, timeZone: jst)
            try await store.begin(context: context)
            let endedAt = Date(timeIntervalSince1970: 1_785_301_200)

            let ref = try await store.finalize(endedAt: endedAt, reason: .stopped)

            #expect(ref?.directoryName == "2026-07-29/1300")
            #expect(ref?.title == nil)
            #expect(ref?.startedAt == context.sessionStartedAt)
            let meta = try SessionMetaCoder.decode(Data(
                contentsOf: dir.appendingPathComponent("2026-07-29/1300/meta.json")
            ))
            #expect(meta.endedAt == endedAt)
        }
    }

    /// 止めた記録は終わり方だけを書き、理由の文言は持たない
    @Test func finalizeRecordsStoppedWithoutMessage() async throws {
        try await withTempDir { dir in
            let store = SessionFileStore(directory: dir, timeZone: jst)
            try await store.begin(context: context)

            _ = try await store.finalize(endedAt: Date(timeIntervalSince1970: 1_785_301_200), reason: .stopped)

            let meta = try SessionMetaCoder.decode(Data(
                contentsOf: dir.appendingPathComponent("2026-07-29/1300/meta.json")
            ))
            #expect(meta.endReason == "stopped")
            #expect(meta.endMessage == nil)
        }
    }

    /// 失敗で閉じた記録には、ポップオーバーに出したのと同じ理由を残す。再起動した後でも何で止まったかを追えるように
    @Test func finalizeRecordsFailureWithMessage() async throws {
        try await withTempDir { dir in
            let store = SessionFileStore(directory: dir, timeZone: jst)
            try await store.begin(context: context)

            _ = try await store.finalize(
                endedAt: Date(timeIntervalSince1970: 1_785_301_200), reason: .failed("マイク: 止まった")
            )

            let meta = try SessionMetaCoder.decode(Data(
                contentsOf: dir.appendingPathComponent("2026-07-29/1300/meta.json")
            ))
            #expect(meta.endReason == "failed")
            #expect(meta.endMessage == "マイク: 止まった")
            #expect(meta.schemaVersion == 2)
        }
    }

    @Test func finalizeWithoutBeginReturnsNil() async throws {
        try await withTempDir { dir in
            let store = SessionFileStore(directory: dir, timeZone: jst)
            let ref = try await store.finalize(endedAt: Date(timeIntervalSince1970: 1_785_301_200), reason: .stopped)
            #expect(ref == nil)
        }
    }

    @Test func recreatesFilesAfterExternalDeletion() async throws {
        try await withTempDir { dir in
            let store = SessionFileStore(directory: dir, timeZone: jst)
            try await store.begin(context: context)
            try await store.append(TestFixtures.segment(text: "一度目"))
            try FileManager.default.removeItem(at: dir.appendingPathComponent("2026-07-29/1300"))

            try await store.append(TestFixtures.segment(text: "復活"))

            let md = try String(
                contentsOf: dir.appendingPathComponent("2026-07-29/1300/transcript.md"), encoding: .utf8
            )
            #expect(md == "# 2026-07-29 13:00\n\n- **13:00:00** 復活\n")
        }
    }

    /// 保存先変更はアクティブセッションに影響せず、次の begin から反映される
    @Test func updateDirectoryAffectsNextSessionOnly() async throws {
        try await withTempDir { dir in
            try await withTempDir { newRoot in
                let store = SessionFileStore(directory: dir, timeZone: jst)
                try await store.begin(context: context)
                await store.updateDirectory(newRoot)
                try await store.append(TestFixtures.segment(text: "旧ルートに残る"))
                _ = try await store.finalize(endedAt: Date(timeIntervalSince1970: 1_785_301_200), reason: .stopped)

                try await store.begin(context: context)

                #expect(FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("2026-07-29/1300/transcript.jsonl").path
                ))
                #expect(FileManager.default.fileExists(
                    atPath: newRoot.appendingPathComponent("2026-07-29/1300").path
                ))
            }
        }
    }

    // MARK: 記録中の meta.json と、開いていることの知らせ

    /// 閉じるときは meta.json を読み直し、終わりだけを足す。記録中にほかの書き手が足した項目を、開いた時点の中身で消さない
    @Test func finalizeKeepsFieldsOthersWroteWhileRecording() async throws {
        try await withTempDir { dir in
            let store = SessionFileStore(directory: dir, timeZone: jst, workLock: SessionWorkLock())
            try await store.begin(context: context)
            let metaURL = dir.appendingPathComponent("2026-07-29/1300/meta.json")
            var written = try SessionMetaCoder.decode(Data(contentsOf: metaURL))
            written.playbookID = "lecture"
            written.pipeline = ["summary": PipelineTaskState(status: .done, outputFile: "summary.md")]
            try SessionMetaCoder.encode(written).write(to: metaURL)

            _ = try await store.finalize(endedAt: Date(timeIntervalSince1970: 1_785_301_200), reason: .stopped)

            let meta = try SessionMetaCoder.decode(Data(contentsOf: metaURL))
            #expect(meta.playbookID == "lecture")
            #expect(meta.pipeline?["summary"]?.status == .done)
            #expect(meta.endedAt == Date(timeIntervalSince1970: 1_785_301_200))
            #expect(meta.endReason == "stopped")
        }
    }

    /// 開いている間は、タイトル付与とパイプラインがこの記録を対象にしないよう、開いていることを知らせる
    @Test func marksTheSessionOpenFromBeginUntilFinalize() async throws {
        try await withTempDir { dir in
            let lock = SessionWorkLock()
            let store = SessionFileStore(directory: dir, timeZone: jst, workLock: lock)
            let live = SessionRef(directoryName: "2026-07-29/1300", title: nil, startedAt: context.sessionStartedAt)
            try await store.begin(context: context)
            #expect(await lock.isOpen(live, in: dir))

            _ = try await store.finalize(endedAt: Date(timeIntervalSince1970: 1_785_301_200), reason: .stopped)

            #expect(await !lock.isOpen(live, in: dir))
        }
    }

    /// meta.json を書けずに閉じられなかった記録も、開いたままにはしない。
    /// 残すと、その記録へのタイトル付与とパイプラインを、アプリを再起動するまで断り続ける
    @Test func failedFinalizeStillClosesTheSession() async throws {
        try await withTempDir { dir in
            let lock = SessionWorkLock()
            let store = SessionFileStore(directory: dir, timeZone: jst, workLock: lock)
            let live = SessionRef(directoryName: "2026-07-29/1300", title: nil, startedAt: context.sessionStartedAt)
            try await store.begin(context: context)
            // ディレクトリをファイルに置き換え、meta.json を書けなくする
            let sessionDir = dir.appendingPathComponent("2026-07-29/1300")
            try FileManager.default.removeItem(at: sessionDir)
            try Data().write(to: sessionDir)

            await #expect(throws: (any Error).self) {
                _ = try await store.finalize(endedAt: Date(timeIntervalSince1970: 1_785_301_200), reason: .stopped)
            }

            #expect(await !lock.isOpen(live, in: dir))
        }
    }

    // MARK: Private

    private func withTempDir(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }
}
