import Foundation

// MARK: - SessionEndReason

/// 記録セッションがどう終わったか。ストアが閉じるときに保存し、後から失敗で終わった記録を見分けられるようにする
public enum SessionEndReason: Sendable, Equatable {
    /// 利用者（ポップオーバー・制御ソケット）が止めた
    case stopped
    /// 無音が続いたためアプリが止めた
    case autoStopped
    /// 記録を続けられなくなった。値はポップオーバーに出す理由と同じ文言
    case failed(String)
}
