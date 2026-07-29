import Foundation

/// 旧日次形式（YYYY-MM-DD.jsonl + .md）をセッションディレクトリへ変換する一回きりの移行ツール。
/// 正本の jsonl は原文行のまま引き継ぎ、md はセッション見出しで再生成する。
/// 変換済みの旧ファイルは .bak へ退避するため、再実行しても二重変換しない（冪等）。
public struct DailyMigrationTool: Sendable {
    // MARK: Lifecycle

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    // MARK: Public

    @discardableResult public func migrate(directory: URL) throws -> [SessionRef] {
        let dailyFiles = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.lastPathComponent.wholeMatch(of: /\d{4}-\d{2}-\d{2}\.jsonl/) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var migrated: [SessionRef] = []
        for file in dailyFiles {
            migrated += try migrateFile(file, in: directory)
        }
        return migrated
    }

    // MARK: Private

    private let timeZone: TimeZone

    private static func headerTitle(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func migrateFile(_ file: URL, in directory: URL) throws -> [SessionRef] {
        let contents = try String(contentsOf: file, encoding: .utf8)
        // (原文行, セグメント) のペアで持ち、正本には原文行をそのまま書く
        let entries: [(line: String, segment: TranscriptSegment)] = contents
            .split(separator: "\n")
            .compactMap { line in
                guard let segment = try? JSONLCoder.decodeLine(String(line)) else { return nil }
                return (String(line), segment)
            }

        var groups: [UUID: [(line: String, segment: TranscriptSegment)]] = [:]
        var order: [UUID] = []
        for entry in entries {
            if groups[entry.segment.sessionID] == nil {
                order.append(entry.segment.sessionID)
            }
            groups[entry.segment.sessionID, default: []].append(entry)
        }

        let formatter = MarkdownFormatter(timeZone: timeZone)
        let namer = SessionDirectoryNamer(timeZone: timeZone)
        var migrated: [SessionRef] = []

        for sessionID in order {
            guard let group = groups[sessionID], let firstSegment = group.first?.segment else { continue }
            let startedAt = firstSegment.sessionStartedAt

            // 日付フォルダ階層（<date>/<HHmm>）へ変換する
            let date = namer.dateComponent(for: startedAt)
            let time = namer.timeComponent(for: startedAt)
            let dateDirectory = directory.appendingPathComponent(date, isDirectory: true)
            var name = time
            var counter = 2
            while FileManager.default.fileExists(atPath: dateDirectory.appendingPathComponent(name).path) {
                name = "\(time)-\(counter)"
                counter += 1
            }
            let sessionDir = dateDirectory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

            try (group.map(\.line).joined(separator: "\n") + "\n").write(
                to: sessionDir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8
            )

            let mdLines = group.compactMap { formatter.line(for: $0.segment) }
            if !mdLines.isEmpty {
                let header = formatter.header(forStem: Self.headerTitle(for: startedAt, timeZone: timeZone))
                try (header + mdLines.joined()).write(
                    to: sessionDir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8
                )
            }

            let meta = SessionMeta(
                sessionID: sessionID,
                startedAt: startedAt,
                endedAt: group.last?.segment.finalizedAt,
                locale: firstSegment.locale,
                source: firstSegment.source
            )
            try SessionMetaCoder.encode(meta).write(
                to: sessionDir.appendingPathComponent("meta.json"), options: .atomic
            )
            migrated.append(SessionRef(directoryName: "\(date)/\(name)", title: nil, startedAt: startedAt))
        }

        try FileManager.default.moveItem(
            at: file, to: file.appendingPathExtension("bak")
        )
        let dailyMarkdown = file.deletingPathExtension().appendingPathExtension("md")
        if FileManager.default.fileExists(atPath: dailyMarkdown.path) {
            try FileManager.default.moveItem(at: dailyMarkdown, to: dailyMarkdown.appendingPathExtension("bak"))
        }
        return migrated
    }
}
