import Foundation

// MARK: - SessionFileStore

/// セッション単位ディレクトリ（<ルート>/<yyyy-MM-dd_HHmm>/）へ保存するストア。
/// 中身は transcript.jsonl（正本・常に書く）+ transcript.md（表示用）+ meta.json。
/// セッションは日を跨いでも同一ディレクトリに書かれ続ける（日次ロールオーバーはしない）。
public actor SessionFileStore: TranscriptStore {
    // MARK: Lifecycle

    public init(directory: URL, timeZone: TimeZone) {
        self.directory = directory
        self.timeZone = timeZone
        namer = SessionDirectoryNamer(timeZone: timeZone)
        formatter = MarkdownFormatter(timeZone: timeZone)
    }

    // MARK: Public

    public func begin(context: TranscriptionContext) throws {
        // 日付フォルダ階層: <ルート>/<yyyy-MM-dd>/<HHmm>/（同分の連番は -2, -3, …）
        let date = namer.dateComponent(for: context.sessionStartedAt)
        let time = namer.timeComponent(for: context.sessionStartedAt)
        let dateDirectory = directory.appendingPathComponent(date, isDirectory: true)
        var name = time
        var counter = 2
        while FileManager.default.fileExists(atPath: dateDirectory.appendingPathComponent(name).path) {
            name = "\(time)-\(counter)"
            counter += 1
        }
        let sessionDirectory = dateDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let meta = SessionMeta(
            sessionID: context.sessionID,
            startedAt: context.sessionStartedAt,
            locale: context.locale,
            source: context.source
        )
        try SessionMetaCoder.encode(meta).write(
            to: sessionDirectory.appendingPathComponent("meta.json"), options: .atomic
        )
        active = ActiveSession(directory: sessionDirectory, relativePath: "\(date)/\(name)", meta: meta)
    }

    public func append(_ segment: TranscriptSegment) throws {
        guard let active else { throw SessionFileStoreError.noActiveSession }
        try FileManager.default.createDirectory(at: active.directory, withIntermediateDirectories: true)

        // JSONL は生データとして常に書く。md は表示可能な本文があるときだけ書く
        let jsonlLine = try JSONLCoder.encodeLine(segment) + "\n"
        try appendString(jsonlLine, to: active.directory.appendingPathComponent("transcript.jsonl"), header: nil)

        if let mdLine = formatter.line(for: segment) {
            let header = formatter.header(forStem: markdownHeaderTitle(for: active.meta.startedAt))
            try appendString(mdLine, to: active.directory.appendingPathComponent("transcript.md"), header: header)
        }
    }

    public func finalize(endedAt: Date) throws -> SessionRef? {
        guard let active else { return nil }
        var meta = active.meta
        meta.endedAt = endedAt
        try SessionMetaCoder.encode(meta).write(
            to: active.directory.appendingPathComponent("meta.json"), options: .atomic
        )
        self.active = nil
        return SessionRef(
            directoryName: active.relativePath,
            title: meta.title,
            startedAt: meta.startedAt
        )
    }

    /// 保存ルートの差し替え。アクティブなセッションには影響せず、次の begin から反映される
    public func updateDirectory(_ url: URL) {
        directory = url
    }

    /// 保存ルート（「フォルダを開く」導線用）
    public func rootDirectory() -> URL {
        directory
    }

    // MARK: Private

    private struct ActiveSession {
        let directory: URL
        /// 保存ルートからの相対パス（SessionRef.directoryName になる）
        let relativePath: String
        let meta: SessionMeta
    }

    private var directory: URL
    private var active: ActiveSession?

    private let timeZone: TimeZone
    private let namer: SessionDirectoryNamer
    private let formatter: MarkdownFormatter

    /// transcript.md の見出し。タイトル確定時の差し替えは TitleAssigner の責務
    private func markdownHeaderTitle(for startedAt: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        return dateFormatter.string(from: startedAt)
    }

    /// 外部削除に自然に強くするため、ハンドルは保持せず毎回開閉する（追記は低頻度）
    private func appendString(_ string: String, to url: URL, header: String?) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(string.utf8))
        } else {
            let content = (header ?? "") + string
            try Data(content.utf8).write(to: url, options: .atomic)
        }
    }
}

// MARK: - SessionFileStoreError

public enum SessionFileStoreError: Error, LocalizedError {
    case noActiveSession

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case .noActiveSession:
            "記録セッションが開始されていません。"
        }
    }
}
