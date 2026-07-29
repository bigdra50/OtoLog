import Foundation

/// 壁時計時刻から日次ファイルの stem（"YYYY-MM-DD"）を決める。
/// 日付→stem の変換はここに一元化し、ロールオーバー判定も stem の比較で行う。
public struct DailyFileNamer: Sendable {
    // MARK: Lifecycle

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    // MARK: Public

    public func stem(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: Private

    private let timeZone: TimeZone
}
