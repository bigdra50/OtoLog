import Foundation

/// 無音で自動停止したことを知らせる文言。次の記録を始めるまでポップオーバーに出す。
/// 止めた時刻を添え、席を外している間に止まった記録がどこまで残っているかを分かるようにする
enum AutoStopNotice {
    // MARK: Internal

    static func message(silence: Duration, stoppedAt: Date, timeZone: TimeZone = .current) -> String {
        "無音が\(length(of: silence))続いたため \(clockTime(of: stoppedAt, in: timeZone)) に自動停止しました"
    }

    // MARK: Private

    /// 設定は分単位なので分で出し、割り切れないときだけ秒で出す
    private static func length(of silence: Duration) -> String {
        let seconds = silence.components.seconds
        return seconds % 60 == 0 ? "\(seconds / 60)分" : "\(seconds)秒"
    }

    /// DateFormatter は Sendable でないため共有せず毎回作る。知らせは記録ごとに1回しか作らない
    private static func clockTime(of date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
