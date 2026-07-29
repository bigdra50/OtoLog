import Foundation

/// claude -p 呼び出しの診断ログ。OTOLOG_CLAUDE_DEBUG=1 のときだけ有効化する。
/// 1呼び出しにつき2ファイル1組:
/// - invocationLogURL: OtoLog 視点のタイムライン（引数・プロンプトサイズ・チャンク受信・終了/エラー）
/// - cliDebugLogURL: claude --debug-file の書き先（API リクエスト・リトライ等の CLI 内部ログ）
public final class ClaudeDebugLog: @unchecked Sendable {
    // MARK: Lifecycle

    public init(directory: URL, label: String = "claude") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(formatter.string(from: Date()))-\(label)-\(UUID().uuidString.prefix(8))"
        invocationLogURL = directory.appendingPathComponent("\(base).log")
        cliDebugLogURL = directory.appendingPathComponent("\(base)-cli.log")
        FileManager.default.createFile(atPath: invocationLogURL.path, contents: nil)
    }

    // MARK: Public

    public let invocationLogURL: URL
    public let cliDebugLogURL: URL

    /// OTOLOG_CLAUDE_DEBUG=1 のとき XDG_STATE_HOME（未設定なら ~/.local/state）/otolog/claude-logs へ作る。
    /// ディレクトリが作れない等の失敗は診断機能なので nil に倒す（本処理を止めない）
    public static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ClaudeDebugLog? {
        guard let flag = environment["OTOLOG_CLAUDE_DEBUG"],
              flag == "1" || flag.lowercased() == "true"
        else { return nil }
        let stateHome = environment["XDG_STATE_HOME"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state", isDirectory: true)
        let directory = stateHome.appendingPathComponent("otolog/claude-logs", isDirectory: true)
        return try? ClaudeDebugLog(directory: directory)
    }

    public func logStart(arguments: [String], promptBytes: Int) {
        lock.withLock { startedAt = Date() }
        append("start args=[\(arguments.joined(separator: " "))] prompt=\(promptBytes) bytes")
        append("cli-debug: \(cliDebugLogURL.path)")
    }

    /// stdout チャンク受信の生存記録。全チャンクだと行数が膨れるため chunkLogInterval で間引く
    public func logChunk(bytes: Int) {
        let shouldWrite: Bool = lock.withLock {
            totalBytes += bytes
            guard let last = lastChunkLoggedAt else {
                lastChunkLoggedAt = Date()
                return true
            }
            guard Date().timeIntervalSince(last) >= Self.chunkLogInterval else { return false }
            lastChunkLoggedAt = Date()
            return true
        }
        if shouldWrite {
            append("chunk total=\(lock.withLock { totalBytes }) bytes")
        }
    }

    public func logFinish(terminationStatus: Int32, stdoutBytes: Int, stderrTail: String) {
        append("finish exit=\(terminationStatus) stdout=\(stdoutBytes) bytes")
        if !stderrTail.isEmpty {
            append("stderr: \(stderrTail)")
        }
    }

    public func logError(_ message: String) {
        append("error: \(message)")
    }

    // MARK: Private

    /// 5秒あれば進行の有無は判断できる。短くすると長時間実行でログ行が数百に膨れる
    private static let chunkLogInterval: TimeInterval = 5

    private let lock = NSLock()
    private var startedAt: Date?
    private var lastChunkLoggedAt: Date?
    private var totalBytes = 0

    /// 経過秒付きの1行を追記する。頻度が低い（間引き済み）ため都度 open/close で足りる
    private func append(_ message: String) {
        let elapsed = lock.withLock {
            startedAt.map { String(format: "+%.1fs ", Date().timeIntervalSince($0)) } ?? ""
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(elapsed)\(message)\n"
        guard let handle = try? FileHandle(forWritingTo: invocationLogURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
