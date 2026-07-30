import Foundation
import OtoLogCore

/// 保存先ディレクトリへセッション一式（meta.json + transcript.jsonl + 任意の生成物）を組み立てる。
enum SessionFixture {
    // MARK: Internal

    static let jst = TimeZone(identifier: "Asia/Tokyo")!

    /// name は日付フォルダ階層の相対パス（例 "2026-07-29/1300"）。開始時刻はここから決める
    @discardableResult static func make(
        in root: URL,
        name: String,
        texts: [String],
        title: String? = nil,
        playbookID: String? = nil,
        pipeline: [String: PipelineTaskState]? = nil,
        documents: [String: String] = [:]
    ) throws -> SessionRef {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let startedAt = startedAt(fromName: name)
        let meta = SessionMeta(
            sessionID: UUID(),
            title: title,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1800),
            locale: "ja-JP",
            source: .system,
            playbookID: playbookID,
            pipeline: pipeline
        )
        try SessionMetaCoder.encode(meta).write(to: dir.appendingPathComponent("meta.json"))

        // 1発話1行。finalizedAt は開始時刻から5秒刻みで進める
        let lines = try texts.enumerated().map { index, text in
            try JSONLCoder.encodeLine(TranscriptSegment(
                text: text,
                audioStart: nil,
                audioEnd: nil,
                finalizedAt: startedAt.addingTimeInterval(Double(index) * 5),
                locale: "ja-JP",
                source: .system,
                sessionID: meta.sessionID,
                sessionStartedAt: startedAt
            ))
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8
        )

        for (fileName, contents) in documents {
            try contents.write(
                to: dir.appendingPathComponent(fileName), atomically: true, encoding: .utf8
            )
        }
        return SessionRef(directoryName: name, title: title, startedAt: startedAt)
    }

    static func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try body(dir)
    }

    @MainActor static func withTempDir(_ body: (URL) async throws -> Void) async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await body(dir)
    }

    // MARK: Private

    private static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogAppTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func startedAt(fromName name: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = jst
        formatter.dateFormat = "yyyy-MM-dd/HHmm"
        return formatter.date(from: name)!
    }
}
