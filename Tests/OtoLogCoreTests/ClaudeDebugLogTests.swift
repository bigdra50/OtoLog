import Foundation
@testable import OtoLogCore
import Testing

struct ClaudeDebugLogTests {
    // MARK: Internal

    /// OTOLOG_CLAUDE_DEBUG が無ければデバッグログは作られない（通常運用でファイルを増やさない契約）
    @Test func fromEnvironmentReturnsNilWithoutFlag() {
        #expect(ClaudeDebugLog.fromEnvironment(environment: [:]) == nil)
        #expect(ClaudeDebugLog.fromEnvironment(environment: ["OTOLOG_CLAUDE_DEBUG": "0"]) == nil)
    }

    /// 有効時は XDG_STATE_HOME/otolog/claude-logs 配下に呼び出しログと CLI デバッグログの2ファイル1組を確保する
    @Test func fromEnvironmentUsesXDGStateHome() throws {
        try withTempDir { dir in
            let log = ClaudeDebugLog.fromEnvironment(environment: [
                "OTOLOG_CLAUDE_DEBUG": "1",
                "XDG_STATE_HOME": dir.path,
            ])
            let unwrapped = try #require(log)
            let expectedDir = dir.appendingPathComponent("otolog/claude-logs").path
            #expect(unwrapped.invocationLogURL.path.hasPrefix(expectedDir))
            #expect(unwrapped.cliDebugLogURL.path.hasPrefix(expectedDir))
            #expect(unwrapped.invocationLogURL != unwrapped.cliDebugLogURL)
            #expect(FileManager.default.fileExists(atPath: unwrapped.invocationLogURL.path))
        }
    }

    /// 開始・チャンク・終了がタイムスタンプ付きで1ファイルに残る
    @Test func writesTimeline() throws {
        try withTempDir { dir in
            let log = try ClaudeDebugLog(directory: dir, label: "test")
            log.logStart(arguments: ["-p", "--model", "sonnet"], promptBytes: 12345)
            log.logChunk(bytes: 100)
            log.logFinish(terminationStatus: 0, stdoutBytes: 678, stderrTail: "警告あり")

            let content = try String(contentsOf: log.invocationLogURL, encoding: .utf8)
            #expect(content.contains("start"))
            #expect(content.contains("--model sonnet"))
            #expect(content.contains("prompt=12345"))
            #expect(content.contains("total=100"))
            #expect(content.contains("exit=0"))
            #expect(content.contains("stdout=678"))
            #expect(content.contains("警告あり"))
        }
    }

    /// チャンク記録は間引く（初回は必ず、直後の連続チャンクは書かない）。
    /// ストリーミングで毎チャンク書くと行数が膨れるため
    @Test func throttlesChunkLines() throws {
        try withTempDir { dir in
            let log = try ClaudeDebugLog(directory: dir, label: "test")
            log.logStart(arguments: [], promptBytes: 0)
            log.logChunk(bytes: 10)
            log.logChunk(bytes: 20)
            log.logChunk(bytes: 30)

            let content = try String(contentsOf: log.invocationLogURL, encoding: .utf8)
            let chunkLines = content.split(separator: "\n").filter { $0.contains("total=") }
            #expect(chunkLines.count == 1)
            #expect(chunkLines[0].contains("total=10"))
        }
    }

    /// timeout 等の throw もログに残す（今回の 600s 失敗が事後に分からなかった反省）
    @Test func writesErrorLine() throws {
        try withTempDir { dir in
            let log = try ClaudeDebugLog(directory: dir, label: "test")
            log.logStart(arguments: [], promptBytes: 0)
            log.logError("コマンドが600秒以内に終了しませんでした")

            let content = try String(contentsOf: log.invocationLogURL, encoding: .utf8)
            #expect(content.contains("error"))
            #expect(content.contains("600秒以内"))
        }
    }

    // MARK: Private

    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }
}
