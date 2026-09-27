import Foundation
@testable import OtoLogCore
import Testing

/// 記録ディレクトリごとの作業の受け持ち。
/// 保存・タイトル付与・パイプライン・単発生成が同じ記録へ手を出すとき、重ねてよい組み合わせだけを通す
struct SessionWorkLockTests {
    let root = URL(fileURLWithPath: "/tmp/otolog-lock-tests", isDirectory: true)
    let session = SessionRef(
        directoryName: "2026-07-29/1300", title: nil, startedAt: Date(timeIntervalSince1970: 1_785_297_600)
    )
    let titled = SessionRef(
        directoryName: "2026-07-29/定例会議", title: "定例会議", startedAt: Date(timeIntervalSince1970: 1_785_297_600)
    )

    // MARK: 記録中

    /// 記録中でも単発生成はできる（README の仕様。その時点までの内容で生成される）
    @Test func generationProceedsWhileRecording() async throws {
        let sut = SessionWorkLock()
        _ = await sut.open(session, in: root)

        let lease = try await sut.acquire(.generation, for: session, in: root)

        #expect(lease.session == session)
    }

    /// 記録中の記録を移すと保存が元の名前でディレクトリを作り直し、パイプラインの状態は閉じるときの書き直しとぶつかる。
    /// 記録は長く続くので、待たせずに断る
    @Test(arguments: [SessionWork.retitle, .pipeline]) func refusesRetitleAndPipelineWhileRecording(work: SessionWork) async {
        let sut = SessionWorkLock()
        _ = await sut.open(session, in: root)

        await #expect(throws: SessionWorkLockError.sessionIsOpen) {
            _ = try await sut.acquire(work, for: session, in: root)
        }
    }

    @Test func acceptsRetitleOnceTheRecordingIsClosed() async throws {
        let sut = SessionWorkLock()
        let recording = await sut.open(session, in: root)
        await sut.release(recording)

        let lease = try await sut.acquire(.retitle, for: session, in: root)

        #expect(lease.session == session)
        #expect(await !sut.isOpen(session, in: root))
    }

    /// 開いている記録は保存ルートごとに答える。別の保存先の同じ名前は開いていない
    @Test func listsOpenSessionsUnderTheRoot() async {
        let sut = SessionWorkLock()
        let elsewhere = URL(fileURLWithPath: "/tmp/otolog-lock-tests-elsewhere", isDirectory: true)
        _ = await sut.open(session, in: root)

        #expect(await sut.openSessionNames(in: root) == ["2026-07-29/1300"])
        #expect(await sut.openSessionNames(in: elsewhere).isEmpty)
        #expect(await sut.isOpen(session, in: root))
        #expect(await !sut.isOpen(session, in: elsewhere))
    }

    // MARK: タイトル付与

    /// タイトル付与はディレクトリを移すので、同じ記録で先に始まった生成が終わるのを待つ
    @Test func retitleWaitsForARunningGeneration() async throws {
        let sut = SessionWorkLock()
        let generation = try await sut.acquire(.generation, for: session, in: root)
        let granted = OrderLog()

        let retitle = Task {
            let lease = try await sut.acquire(.retitle, for: session, in: root)
            granted.append("retitle")
            return lease
        }
        #expect(await eventually { await sut.waitingCount(for: session, in: root) == 1 })
        #expect(granted.entries.isEmpty)

        await sut.release(generation)

        #expect(try await retitle.value.session == session)
    }

    /// タイトル付与を待っていた作業は、移った先の記録を受け持つ
    @Test func workWaitingBehindARetitleFollowsTheMove() async throws {
        let sut = SessionWorkLock()
        let retitle = try await sut.acquire(.retitle, for: session, in: root)
        let generation = Task { try await sut.acquire(.generation, for: session, in: root) }
        #expect(await eventually { await sut.waitingCount(for: session, in: root) == 1 })

        await sut.release(retitle, movedTo: titled)

        #expect(try await generation.value.session == titled)
    }

    /// 移った後に古い参照（一覧を読み直す前の画面）から来た作業も、移った先を受け持つ
    @Test func staleReferenceFollowsTheMove() async throws {
        let sut = SessionWorkLock()
        let retitle = try await sut.acquire(.retitle, for: session, in: root)
        await sut.release(retitle, movedTo: titled)

        let lease = try await sut.acquire(.generation, for: session, in: root)

        #expect(lease.session == titled)
    }

    /// 移った後に同じ名前で始まった別の記録は、移った先へ向けない。開始時刻で見分ける
    @Test func anotherSessionReusingTheOldNameIsNotRedirected() async throws {
        let sut = SessionWorkLock()
        let retitle = try await sut.acquire(.retitle, for: session, in: root)
        await sut.release(retitle, movedTo: titled)
        let next = SessionRef(
            directoryName: session.directoryName, title: nil, startedAt: session.startedAt.addingTimeInterval(30)
        )
        await sut.release(sut.open(next, in: root))

        let lease = try await sut.acquire(.generation, for: next, in: root)

        #expect(lease.session == next)
    }

    /// 付け直しで前の名前へ戻っても、移り先をたどり続けない
    @Test func retitlingBackToAnEarlierNameEndsAtTheLatestPlace() async throws {
        let sut = SessionWorkLock()
        let other = SessionRef(
            directoryName: "2026-07-29/会議", title: "会議", startedAt: session.startedAt
        )
        try await sut.release(sut.acquire(.retitle, for: session, in: root), movedTo: titled)
        try await sut.release(sut.acquire(.retitle, for: titled, in: root), movedTo: other)
        try await sut.release(sut.acquire(.retitle, for: other, in: root), movedTo: titled)

        let lease = try await sut.acquire(.generation, for: session, in: root)

        #expect(lease.session == titled)
    }

    // MARK: パイプライン

    /// パイプラインは meta.json を読み直して自分の状態を書くので、同じ記録では重ねない
    @Test func pipelinesOnTheSameSessionDoNotOverlap() async throws {
        let sut = SessionWorkLock()
        let first = try await sut.acquire(.pipeline, for: session, in: root)
        let granted = OrderLog()
        let second = Task {
            let lease = try await sut.acquire(.pipeline, for: session, in: root)
            granted.append("second")
            return lease
        }
        #expect(await eventually { await sut.waitingCount(for: session, in: root) == 1 })
        #expect(granted.entries.isEmpty)

        await sut.release(first)

        #expect(try await second.value.session == session)
    }

    @Test func pipelineAndGenerationOverlap() async throws {
        let sut = SessionWorkLock()
        _ = try await sut.acquire(.pipeline, for: session, in: root)

        let generation = try await sut.acquire(.generation, for: session, in: root)

        #expect(generation.session == session)
    }

    @Test func workOnOtherSessionsDoesNotWait() async throws {
        let sut = SessionWorkLock()
        _ = try await sut.acquire(.retitle, for: session, in: root)

        let other = try await sut.acquire(.retitle, for: titled, in: root)

        #expect(other.session == titled)
    }

    // MARK: 順番と取り消し

    /// 待っているタイトル付与より後に来た作業は、その後ろに並ぶ。生成が続けて来てもタイトル付与を待たせ続けない
    @Test func laterArrivalsQueueBehindAWaitingRetitle() async throws {
        let sut = SessionWorkLock()
        let first = try await sut.acquire(.generation, for: session, in: root)
        let order = OrderLog()
        let retitle = Task {
            let lease = try await sut.acquire(.retitle, for: session, in: root)
            order.append("retitle")
            return lease
        }
        #expect(await eventually { await sut.waitingCount(for: session, in: root) == 1 })
        let second = Task {
            let lease = try await sut.acquire(.generation, for: session, in: root)
            order.append("generation")
            return lease
        }
        #expect(await eventually { await sut.waitingCount(for: session, in: root) == 2 })

        await sut.release(first)
        let retitleLease = try await retitle.value
        #expect(order.entries == ["retitle"])
        await sut.release(retitleLease, movedTo: titled)

        #expect(try await second.value.session == titled)
        #expect(order.entries == ["retitle", "generation"])
    }

    /// 待っている間に取り消された作業は並びから外れ、後の受け持ちを止めない
    @Test func cancelledWaiterLeavesTheQueue() async throws {
        let sut = SessionWorkLock()
        let retitle = try await sut.acquire(.retitle, for: session, in: root)
        let waiting = Task { try await sut.acquire(.generation, for: session, in: root) }
        #expect(await eventually { await sut.waitingCount(for: session, in: root) == 1 })

        waiting.cancel()

        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
        #expect(await sut.waitingCount(for: session, in: root) == 0)
        await sut.release(retitle)
        let next = try await sut.acquire(.retitle, for: session, in: root)
        #expect(next.session == session)
    }
}
