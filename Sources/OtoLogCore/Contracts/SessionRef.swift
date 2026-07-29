import Foundation

// MARK: - SessionRef

/// 記録済みセッションへの参照。ディレクトリ名が唯一の識別子で、
/// UI の一覧表示から後処理の対象指定までこの型で受け渡す。
public struct SessionRef: Sendable, Equatable, Identifiable, Codable {
    // MARK: Lifecycle

    public init(directoryName: String, title: String?, startedAt: Date) {
        self.directoryName = directoryName
        self.title = title
        self.startedAt = startedAt
    }

    // MARK: Public

    public let directoryName: String
    public let title: String?
    public let startedAt: Date

    public var id: String {
        directoryName
    }

    /// UI 表示名。タイトル未設定ならディレクトリ名の末尾（日付フォルダ階層なら時刻部分）
    public var displayName: String {
        title ?? directoryName.components(separatedBy: "/").last ?? directoryName
    }
}
