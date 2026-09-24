import Foundation

// MARK: - CaptureRestartDecision

/// 中断したキャプチャを再起動するか、諦めてセッションを失敗させるか
public enum CaptureRestartDecision: Sendable, Equatable {
    /// attempt は連続何回目の再起動か（1始まり）
    case restart(attempt: Int)
    case giveUp
}

// MARK: - CaptureRestartPolicy

/// 記録中に中断したキャプチャを、どこまで再起動するかの規則。
///
/// マイクは音声構成が変わるたび（デバイスの切り替え、サンプルレートの変更、他アプリの通話の開始・終了）に止まるため、
/// 何時間も記録していれば中断は何度も起きる。記録全体で回数を数えると、時間をおいた無関係な中断で失敗してしまう。
/// そこで連続した中断だけを数え、しばらく安定して動いたら数え直す
public struct CaptureRestartPolicy: Sendable, Equatable {
    /// 1回の構成変更による中断は、1秒待ってから再起動すれば数回のうちに収まる想定。
    /// 連続3回を超えて止まり続けるのは、デバイスが使えなくなったとみなして失敗として知らせる。
    /// 1分動き続ければその変更は収まったとみなし、次の中断は別の出来事として数え直す
    public static let `default` = CaptureRestartPolicy(
        maxConsecutiveRestarts: 3, stableInterval: .seconds(60), settleDelay: .seconds(1)
    )

    /// 連続して再起動する上限。これを超えて中断したら諦める
    public var maxConsecutiveRestarts: Int
    /// 前回の再起動からこれ以上動いていれば、次の中断は連続とみなさず1回目から数え直す（境界を含む）
    public var stableInterval: Duration
    /// 止めたキャプチャを再起動するまでの待ち。1回の構成変更で続けて届く通知を、再起動の前にやり過ごす
    public var settleDelay: Duration

    /// consecutiveRestarts はこれまでに連続して再起動した回数、lastRestartAt は最後に再起動した時刻。
    /// lastRestartAt が nil なら、まだ再起動していないものとして1回目から数える
    public func decision(consecutiveRestarts: Int, lastRestartAt: Date?, now: Date) -> CaptureRestartDecision {
        let startsOver = lastRestartAt.map { now.timeIntervalSince($0) >= stableInterval / .seconds(1) } ?? true
        let attempt = (startsOver ? 0 : consecutiveRestarts) + 1
        return attempt <= maxConsecutiveRestarts ? .restart(attempt: attempt) : .giveUp
    }
}
