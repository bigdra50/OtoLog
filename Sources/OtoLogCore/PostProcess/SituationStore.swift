import Foundation

// MARK: - SituationError

public enum SituationError: Error, LocalizedError {
    case emptyUpdate

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case .emptyUpdate: "現況メモの更新結果が空でした。既存の内容は残しています。"
        }
    }
}

// MARK: - SituationStore

/// 現況メモ（<XDG_CONFIG_HOME>/otolog/context.md）の置き場。
///
/// 用語集やアクションと違って型を決めない。「先方の担当者が変わってから進みが遅い」のような
/// ニュアンスは構造にはめると死ぬので、書く内容も残す内容も Claude の裁量に任せる。
/// そのぶん丸ごと書き換わる事故が起きうるので、直前の版を必ず退避する。
public struct SituationStore: Sendable {
    // MARK: Lifecycle

    public init(fileURL: URL = SituationStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    // MARK: Public

    public static var defaultFileURL: URL {
        let environment = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let base = environment.flatMap { path in
            path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("otolog/context.md")
    }

    /// 直前の版。裁量で消された内容を取り戻せるようにしておく
    public var previousURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("previous.md")
    }

    public func load() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    /// 空での上書きは拒む。生成が失敗したときに現況が消えるのが最悪の事故
    public func save(_ contents: String) throws {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SituationError.emptyUpdate }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let existing = load()
        if !existing.isEmpty {
            try? existing.write(to: previousURL, atomically: true, encoding: .utf8)
        }
        try trimmed.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: Private

    private let fileURL: URL
}
