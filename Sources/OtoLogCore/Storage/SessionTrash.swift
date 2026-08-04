import Foundation

// MARK: - SessionTrash

/// セッションディレクトリの削除。
/// 誤操作から戻せるように完全削除（removeItem）はせず、ゴミ箱移動に限定する。
public enum SessionTrash {
    /// 保存ルート配下のセッションディレクトリを解決する。
    /// 削除対象の組み立てに使うため、ルートの外を指しうる相対パス
    /// （空・絶対パス・「.」「..」を含む）は nil にする
    public static func resolveDirectory(root: URL, relativePath: String) -> URL? {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !relativePath.hasPrefix("/"),
              !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." })
        else { return nil }
        return components.reduce(root) { $0.appendingPathComponent($1) }
    }

    /// セッションディレクトリをフォルダごとゴミ箱へ移す
    public static func moveToTrash(root: URL, relativePath: String) throws {
        guard let target = resolveDirectory(root: root, relativePath: relativePath) else {
            throw SessionTrashError.invalidSessionPath(relativePath)
        }
        try FileManager.default.trashItem(at: target, resultingItemURL: nil)
    }
}

// MARK: - SessionTrashError

public enum SessionTrashError: Error, Equatable, LocalizedError {
    case invalidSessionPath(String)

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case let .invalidSessionPath(path):
            "セッションの場所を特定できないため削除を中止しました: \(path)"
        }
    }
}
