import Foundation

/// 旧フラット構造（<ルート>/<yyyy-MM-dd_HHmm>[_<タイトル>]/）のセッションを
/// 日付フォルダ階層（<ルート>/<yyyy-MM-dd>/<タイトル or HHmm>/）へ移動する一回きりの移行ツール。
/// 移動のみでファイル内容は変えない。再実行しても対象が無くなるだけ（冪等）。
public struct StructureMigrationTool: Sendable {
    // MARK: Lifecycle

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    // MARK: Public

    @discardableResult public func migrate(directory: URL) throws -> [SessionRef] {
        let flatSessions = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? [])
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && url.lastPathComponent.prefixMatch(of: /\d{4}-\d{2}-\d{2}_\d{4}/) != nil
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let namer = SessionDirectoryNamer(timeZone: timeZone)
        var migrated: [SessionRef] = []

        for source in flatSessions {
            let flatName = source.lastPathComponent
            let meta = (try? Data(contentsOf: source.appendingPathComponent("meta.json")))
                .flatMap { try? SessionMetaCoder.decode($0) }
            guard let startedAt = meta?.startedAt
                ?? namer.parseStartedAt(fromRelativePath: flatName) else { continue }

            let date = namer.dateComponent(for: startedAt)
            let preferred = meta?.title.flatMap { SessionDirectoryNamer.sanitizeTitle($0) }
                ?? namer.timeComponent(for: startedAt)
            let dateDirectory = directory.appendingPathComponent(date, isDirectory: true)
            try FileManager.default.createDirectory(at: dateDirectory, withIntermediateDirectories: true)

            var name = preferred
            var counter = 2
            while FileManager.default.fileExists(atPath: dateDirectory.appendingPathComponent(name).path) {
                name = "\(preferred)-\(counter)"
                counter += 1
            }
            try FileManager.default.moveItem(at: source, to: dateDirectory.appendingPathComponent(name))
            migrated.append(SessionRef(
                directoryName: "\(date)/\(name)", title: meta?.title, startedAt: startedAt
            ))
        }
        return migrated
    }

    // MARK: Private

    private let timeZone: TimeZone
}
