import Foundation

// MARK: - SilenceMonitor

/// 記録中の無音を見張る。発話とみなせる結果が timeout のあいだ届かなければ、無音が続いたとみなす。
///
/// 会議の後に止め忘れた記録が、無音のまま何時間も録り続けないようにするための判定。
/// 時刻は呼び出し側が渡し、ここは経過時間の比較だけを行う
public struct SilenceMonitor: Sendable {
    // MARK: Lifecycle

    /// startedAt から無音を数え始める。記録を始めてから一度も話されなければ、ここから timeout で無音が続いたとみなす
    public init(timeout: Duration, startedAt: Date) {
        self.timeout = timeout
        lastActivityAt = startedAt
    }

    // MARK: Public

    /// 文字（文字体系を問わない）か数字を1つでも含めば発話とみなす。
    /// 認識器は雑音にも句読点だけの結果（", , ,"）を返すため、結果が届いたことだけでは発話とみなさない
    public static func isActivity(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// 発話とみなせるテキストなら、date から無音を数え直す
    public mutating func recordActivity(_ text: String, at date: Date) {
        guard Self.isActivity(text) else { return }
        lastActivityAt = date
    }

    /// 最後の発話（無ければ開始）から timeout 以上たったか（境界を含む）
    public func isExpired(at date: Date) -> Bool {
        date.timeIntervalSince(lastActivityAt) >= timeout / .seconds(1)
    }

    // MARK: Internal

    /// 無音とみなすまでの長さ。自動停止を知らせるイベントに載せる
    let timeout: Duration

    // MARK: Private

    private var lastActivityAt: Date
}
