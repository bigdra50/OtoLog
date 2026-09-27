import Foundation

// MARK: - TranscriptEventRelay

/// SpeechAnalyzerEngine が、ロケールごとの結果を1本のイベント列へ送り出す部分。
/// Speech フレームワークに依らないため、単体で確かめられる。
///
/// - 裁定と送り出しは同じロックの中で行う。結果の購読はロケールごとに並行するため、ロックの外で送ると、
///   言語が決まった時点でまとめて出す保留分と、その後に別の購読から届いた確定結果の順序が入れ替わる
/// - 入力の終わりの吐き出し（drain）は、最初の呼び出しだけが進め、後の呼び出しはその終わりを待つ。
///   エンジンでは feedTask と finish() の両方から呼ばれる。2つが並ぶと、一方の finalize が確定させている間に
///   他方がイベント列を閉じ、最後の結果と判定待ちの保留分を落とす
/// - drain は finalize が戻った後、結果を受けるタスクの終わりを待ってから、保留分を出して閉じる。
///   finalize が戻った時点では、最後の確定結果がまだ受け手に届いていないことがある
final class TranscriptEventRelay: @unchecked Sendable {
    // MARK: Lifecycle

    /// candidates の先頭は、言語が決まらないまま終わったときの落としどころ。
    /// resultsTimeout は、結果を受けるタスクの終わりを待つ上限（既定値の根拠は defaultResultsTimeout を参照）
    init(
        candidates: [String],
        continuation: AsyncThrowingStream<TranscriptEvent, any Error>.Continuation,
        resultsTimeout: Duration = TranscriptEventRelay.defaultResultsTimeout,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        arbiter = LanguageArbiter(candidates: candidates)
        self.continuation = continuation
        self.resultsTimeout = resultsTimeout
        self.sleep = sleep
    }

    // MARK: Internal

    /// finalize が戻れば結果の列はすぐに終わる。これは終わらない列があっても閉じる処理を止めないための上限で、
    /// 待ちきれなかった結果は落ちる。待つのは列が終わらないときだけで、停止にかかる時間はこの長さまでしか延びない
    static let defaultResultsTimeout: Duration = .seconds(2)

    var decidedLocale: String? {
        lock.withLock { arbiter.decidedLocale }
    }

    /// 確定結果。裁定を通して、出してよいものを送る
    func relay(final segment: TranscriptSegment) {
        lock.withLock {
            for emitted in arbiter.accept(segment) {
                continuation.yield(.finalized(emitted))
            }
        }
    }

    /// 途中経過。これで言語が決まったら、保留していた確定結果を先に送る（途中経過より前に話されたもの）
    func relay(volatile text: String, locale: String) {
        lock.withLock {
            let outcome = arbiter.acceptVolatile(text: text, locale: locale)
            for segment in outcome.released {
                continuation.yield(.finalized(segment))
            }
            if let display = outcome.display {
                continuation.yield(.volatile(display))
            }
        }
    }

    /// 結果を受けるタスクを覚える。閉じる前にこれらの終わりを待つ
    func track(_ task: Task<Void, Never>) {
        lock.withLock { resultsTasks.append(task) }
    }

    /// 入力の終わりの吐き出し。何度呼ばれても1回だけ進め、どの呼び出しもイベント列を閉じ終えてから戻る。
    /// 手順は別のタスクで走らせる。呼び出し側のタスクが取り消されていても、finalize を CancellationError で抜けさせない
    func drain(finalize: @escaping @Sendable () async -> Void) async {
        let task = lock.withLock {
            if let draining { return draining }
            let started = Task { await self.runDrain(finalize: finalize) }
            draining = started
            return started
        }
        await task.value
    }

    // MARK: Private

    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<TranscriptEvent, any Error>.Continuation
    private let resultsTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var arbiter: LanguageArbiter
    private var resultsTasks: [Task<Void, Never>] = []
    private var draining: Task<Void, Never>?

    private func runDrain(finalize: @Sendable () async -> Void) async {
        await finalize()
        await waitForResults()
        lock.withLock {
            // 言語が決まらないまま終わったぶんを、候補の先頭で出す
            for segment in arbiter.flush() {
                continuation.yield(.finalized(segment))
            }
            // results シーケンスの終わりに頼らず、イベント列はここで閉じる
            continuation.finish()
        }
    }

    /// 結果を受けるタスクの終わりを待つ。上限を過ぎたら、残ったタスクを取り消して先へ進む
    private func waitForResults() async {
        let tasks = lock.withLock { resultsTasks }
        guard !tasks.isEmpty else { return }
        let ended = await awaitAtMost(resultsTimeout, sleep: sleep) {
            for task in tasks {
                await task.value
            }
        }
        if !ended {
            SpeechAnalyzerEngine.trace("results did not end within \(resultsTimeout); cancelling")
            for task in tasks {
                task.cancel()
            }
        }
    }
}
