import Foundation
@testable import OtoLogCore
import Testing

/// SpeechAnalyzerEngine がロケールごとの結果を1本のイベント列へ送り出す部分。
/// 言語の判定を待つ間の保留と、入力の終わりの吐き出し（drain）で、確定結果を落とさないことを確かめる
struct TranscriptEventRelayTests {
    // MARK: Internal

    let japanese = "本日はボクセルレンダリングの大規模化についてお話しします。ボクツリーは破綻します。"

    // MARK: 言語の判定

    /// 途中経過で言語が決まったら、保留していた確定結果を、その途中経過より先に送る
    @Test func sendsHeldFinalsBeforeTheVolatileThatDecides() async throws {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, any Error>.makeStream()
        let sut = TranscriptEventRelay(candidates: ["en-US", "ja-JP"], continuation: continuation)
        let opening = segment(text: "はい、始めます", locale: "ja-JP")

        sut.relay(final: opening)
        sut.relay(volatile: japanese, locale: "ja-JP")
        continuation.finish()

        #expect(try await collect(stream) == [.finalized(opening), .volatile(japanese)])
        #expect(sut.decidedLocale == "ja-JP")
    }

    // MARK: 入力の終わり

    /// feedTask と finish() から同時に呼ばれても、吐き出しは1回だけ走り、どちらもイベント列を閉じ終えてから戻る
    @Test func drainRunsOnceForConcurrentCalls() async throws {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, any Error>.makeStream()
        let sut = TranscriptEventRelay(candidates: ["ja-JP"], continuation: continuation)
        let finalizations = OrderLog()
        let gate = ManualSleep(holding: true)
        let finalize: @Sendable () async -> Void = {
            finalizations.append("finalize")
            await gate.sleep(for: .zero)
        }

        let first = Task { await sut.drain(finalize: finalize) }
        let second = Task { await sut.drain(finalize: finalize) }
        #expect(await eventually { gate.waitingCount == 1 })
        gate.release()
        await first.value
        await second.value

        #expect(finalizations.entries == ["finalize"])
        #expect(try await collect(stream).isEmpty)
    }

    /// 言語が決まらないまま終わった記録は、保留分を候補の先頭で出してから閉じる。
    /// 2つの吐き出しが並ぶと、一方が保留分を出す前に他方が閉じ、短い記録の全文が消えることがあった
    @Test func concurrentDrainsSendTheHeldFinalsBeforeClosing() async throws {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, any Error>.makeStream()
        let sut = TranscriptEventRelay(candidates: ["ja-JP", "en-US"], continuation: continuation)
        let short = segment(text: "みじかい", locale: "ja-JP")
        sut.relay(final: short)

        async let first: Void = sut.drain(finalize: {})
        async let second: Void = sut.drain(finalize: {})
        _ = await (first, second)

        #expect(try await collect(stream) == [.finalized(short)])
    }

    /// finalize が戻った後に届いた確定結果も、閉じる前に送る。結果を受けるタスクが終わるのを待ってから閉じる
    @Test func drainWaitsForResultsDeliveredAfterFinalize() async throws {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, any Error>.makeStream()
        let timeout = ManualSleep(holding: true)
        let sut = TranscriptEventRelay(
            candidates: ["ja-JP"], continuation: continuation, sleep: { await timeout.sleep(for: $0) }
        )
        let finalized = ManualSleep(holding: true)
        let last = segment(text: "最後の発話", locale: "ja-JP")
        sut.track(Task {
            // 受け手が最後の結果を取り出すのは、finalize が戻った少し後
            await finalized.sleep(for: .zero)
            try? await Task.sleep(for: .milliseconds(50))
            sut.relay(final: last)
        })

        await sut.drain(finalize: { finalized.release() })

        #expect(try await collect(stream) == [.finalized(last)])
    }

    /// 結果を受けるタスクが終わらなくても、上限を過ぎたら閉じる。終わらないタスクは取り消す
    @Test func drainStopsWaitingForResultsThatNeverEnd() async throws {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, any Error>.makeStream()
        let sut = TranscriptEventRelay(candidates: ["ja-JP"], continuation: continuation, sleep: { _ in })
        let stuck = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(3600))
        }
        sut.track(stuck)

        await sut.drain(finalize: {})

        #expect(try await collect(stream).isEmpty)
        #expect(stuck.isCancelled)
    }

    // MARK: Private

    private func collect(_ stream: AsyncThrowingStream<TranscriptEvent, any Error>) async throws -> [TranscriptEvent] {
        var events: [TranscriptEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    private func segment(text: String, locale: String) -> TranscriptSegment {
        TranscriptSegment(
            text: text, audioStart: nil, audioEnd: nil,
            finalizedAt: Date(timeIntervalSince1970: 1_785_297_600),
            locale: locale, source: .system,
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sessionStartedAt: Date(timeIntervalSince1970: 1_785_297_600)
        )
    }
}
