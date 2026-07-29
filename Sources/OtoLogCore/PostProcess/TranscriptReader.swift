import Foundation

// MARK: - TranscriptReader

/// 保存ルートから記録済みセッションを読む。書き込みは一切しない。
/// 保存構造（ディレクトリ名・ファイル名）に関する読み取り知識はここに集約する。
public struct TranscriptReader: Sendable {
    // MARK: Lifecycle

    public init(directory: URL, timeZone: TimeZone) {
        self.directory = directory
        self.timeZone = timeZone
    }

    // MARK: Public

    /// セッションディレクトリ（yyyy-MM-dd_HHmm で始まる名前）を新しい順で列挙する。
    /// meta.json が読めない場合も相対パスから開始時刻を復元して一覧に含める。
    /// 現行の日付フォルダ階層（<yyyy-MM-dd>/<セッション>）と旧フラット構造の両方を列挙する。
    /// 保存ルート不在は空配列
    public func availableSessions() -> [SessionRef] {
        guard let topLevel = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var refs: [SessionRef] = []
        for url in topLevel where isDirectory(url) {
            let name = url.lastPathComponent
            if name.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil {
                // 日付フォルダ: 子ディレクトリがセッション
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey]
                )) ?? []
                for child in children where isDirectory(child) {
                    if let ref = sessionRef(relativePath: "\(name)/\(child.lastPathComponent)", directory: child) {
                        refs.append(ref)
                    }
                }
            } else if name.prefixMatch(of: /\d{4}-\d{2}-\d{2}_\d{4}/) != nil {
                // 旧フラット構造のセッション（briefs/ 等の無関係ディレクトリはどちらにも該当しない）
                if let ref = sessionRef(relativePath: name, directory: url) {
                    refs.append(ref)
                }
            }
        }
        return refs.sorted { lhs, rhs in
            lhs.startedAt != rhs.startedAt
                ? lhs.startedAt > rhs.startedAt
                : lhs.directoryName > rhs.directoryName
        }
    }

    /// セッションの meta.json を読む（破損・欠損は nil）
    public func meta(in ref: SessionRef) -> SessionMeta? {
        let url = directory.appendingPathComponent(ref.directoryName).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? SessionMetaCoder.decode(data)
    }

    /// セッション内の生成物ファイル名（<テンプレートID>.md）を返す。transcript.md は含まない。
    /// 表示順はテンプレート定義に依存するため、並べ替えは呼び出し側の責務
    public func generatedDocumentFileNames(in ref: SessionRef) -> [String] {
        let sessionDirectory = directory.appendingPathComponent(ref.directoryName)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: sessionDirectory, includingPropertiesForKeys: nil
        ) else { return [] }
        return urls
            .map(\.lastPathComponent)
            .filter { $0.hasSuffix(".md") && $0 != "transcript.md" }
    }

    /// 壊れ行（クラッシュ時の途中行や録音中の追記競合）はスキップして読めたセグメントを返す
    public func segments(in ref: SessionRef) throws -> [TranscriptSegment] {
        let url = directory.appendingPathComponent(ref.directoryName).appendingPathComponent("transcript.jsonl")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw TranscriptReaderError.transcriptNotFound(session: ref.displayName)
        }
        return contents
            .split(separator: "\n")
            .compactMap { try? JSONLCoder.decodeLine(String($0)) }
    }

    // MARK: Private

    private let directory: URL
    private let timeZone: TimeZone

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func sessionRef(relativePath: String, directory url: URL) -> SessionRef? {
        if let data = try? Data(contentsOf: url.appendingPathComponent("meta.json")),
           let meta = try? SessionMetaCoder.decode(data) {
            return SessionRef(directoryName: relativePath, title: meta.title, startedAt: meta.startedAt)
        }
        // meta 欠損・破損時のフォールバック: 相対パス（新旧両形式）から復元
        guard let startedAt = SessionDirectoryNamer(timeZone: timeZone)
            .parseStartedAt(fromRelativePath: relativePath) else { return nil }
        return SessionRef(directoryName: relativePath, title: nil, startedAt: startedAt)
    }
}

// MARK: - TranscriptReaderError

public enum TranscriptReaderError: Error, LocalizedError {
    case transcriptNotFound(session: String)

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case let .transcriptNotFound(session):
            "このセッションの記録ファイルが見つかりません: \(session)"
        }
    }
}
