import Foundation

/// 保存先を読む処理を MainActor から外して実行する。
/// 保存先は外部ボリュームでありうるため、未承認アプリの初回アクセスは open(2) が
/// TCC 承認待ちでブロックし、MainActor 上で行うと UI と制御ソケット応答が全滅する。
/// 保存先（settings.saveDirectory）配下への同期 FS アクセスは必ずここを通す。
enum OffMainIO {
    /// 既定 .userInitiated: 呼び出し元の大半はユーザー操作直後の表示読み込みのため
    static func read<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await Task.detached(priority: priority) { work() }.value
    }
}
