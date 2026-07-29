import Foundation
@testable import OtoLogCore
import Testing

struct ClaudeCLIGeneratorTests {
    // MARK: Internal

    /// 安全フラグの契約: ツール全無効・セッション残さない・スラッシュコマンド無効・thinking 無効・effort 固定。
    /// 変更は claude CLI 側の互換確認（mise run test:claude）とセットで行う
    @Test func defaultArgumentsArePinned() {
        #expect(ClaudeCLIGenerator.defaultArguments == [
            "-p", "--output-format", "text", "--tools", "",
            "--no-session-persistence", "--disable-slash-commands",
            "--settings", ClaudeCLIGenerator.overrideSettingsJSON,
        ])
        #expect(ClaudeCLIGenerator.overrideSettingsJSON.contains(#""alwaysThinkingEnabled": false"#))
        #expect(ClaudeCLIGenerator.overrideSettingsJSON.contains(#""CLAUDE_CODE_EFFORT_LEVEL": "high""#))
    }

    /// claude -p はエラーを stdout（stream-json の result）へ出すことがあり、stderr が空だと
    /// エラー内容が失われる。stderr 空のときは stdout 末尾を診断に使う
    @Test func nonZeroExitFallsBackToStdoutWhenStderrEmpty() async {
        let generator = ClaudeCLIGenerator(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo 'API Error: 400 effort not supported'; exit 1"]
        )
        do {
            _ = try await generator.generate(prompt: "x")
            Issue.record("nonZeroExit になるはず")
        } catch let error as ClaudeCLIGeneratorError {
            guard case let .nonZeroExit(_, diagnostic) = error else {
                Issue.record("想定外のエラー: \(error)")
                return
            }
            #expect(diagnostic.contains("API Error: 400"))
        } catch {
            Issue.record("想定外のエラー型: \(error)")
        }
    }

    @Test func passesPromptThroughStdinAndReturnsStdout() async throws {
        let generator = ClaudeCLIGenerator(executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [])
        let output = try await generator.generate(prompt: "テストプロンプト")
        #expect(output == "テストプロンプト")
    }

    @Test func throwsWhenExecutableMissing() async {
        let generator = ClaudeCLIGenerator(executableURL: URL(fileURLWithPath: "/nonexistent/claude-\(UUID())"))
        await #expect(throws: ClaudeCLIGeneratorError.self) {
            _ = try await generator.generate(prompt: "x")
        }
    }

    /// 未ログインや context 超過は claude が非0 + stderr で返すため、stderr を診断に含める契約
    @Test func throwsNonZeroExitIncludingStderr() async {
        let generator = ClaudeCLIGenerator(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo 認証エラー 1>&2; exit 2"]
        )
        do {
            _ = try await generator.generate(prompt: "x")
            Issue.record("nonZeroExit になるはず")
        } catch let error as ClaudeCLIGeneratorError {
            guard case let .nonZeroExit(code, stderr) = error else {
                Issue.record("想定外のエラー: \(error)")
                return
            }
            #expect(code == 2)
            #expect(stderr.contains("認証エラー"))
        } catch {
            Issue.record("想定外のエラー型: \(error)")
        }
    }

    @Test func throwsEmptyOutputForBlankStdout() async {
        let generator = ClaudeCLIGenerator(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '  \n'"]
        )
        await #expect(throws: ClaudeCLIGeneratorError.self) {
            _ = try await generator.generate(prompt: "x")
        }
    }

    /// ストリーミング版は text 指定を stream-json 一式へ差し替える
    @Test func streamingArgumentsReplaceTextOutputFormat() {
        let streaming = ClaudeCLIGenerator.streamingArguments(from: ClaudeCLIGenerator.defaultArguments)
        #expect(streaming.contains("stream-json"))
        #expect(streaming.contains("--include-partial-messages"))
        #expect(streaming.contains("--verbose"))
        #expect(!streaming.contains("text"))
        // text 指定が無い引数（テスト注入等）はそのまま
        #expect(ClaudeCLIGenerator.streamingArguments(from: []) == [])
    }

    /// stream-json のデルタが onPartial へ流れ、最終テキストは result イベントから取れる
    @Test func streamsPartialsAndExtractsResult() async throws {
        let script = """
        printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"thinking":"考え中"}}}'
        printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"text":"本文A"}}}'
        printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"text":"本文B"}}}'
        printf '%s\\n' '{"type":"result","subtype":"success","result":"最終テキスト"}'
        """
        let generator = ClaudeCLIGenerator(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script]
        )
        let collector = PartialCollector()
        let output = try await generator.generate(prompt: "x") { collector.append($0) }
        #expect(output == "最終テキスト")
        #expect(collector.values.contains("考え中"))
        #expect(collector.values.contains("本文A"))
    }

    /// デバッグログ注入時は --debug-file が引数に足され、呼び出しタイムラインが残る
    @Test func debugLogCapturesInvocationAndAddsDebugFileFlag() async throws {
        try await withTempDir { dir in
            let script = dir.appendingPathComponent("echo-args.sh")
            try "#!/bin/sh\nprintf '%s ' \"$@\"\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

            let debugLog = try ClaudeDebugLog(directory: dir, label: "gen")
            let generator = ClaudeCLIGenerator(
                executableURL: script, arguments: ["--flag"], debugLogFactory: { debugLog }
            )
            let output = try await generator.generate(prompt: "プロンプト")
            #expect(output.contains("--debug-file"))
            #expect(output.contains(debugLog.cliDebugLogURL.path))

            let content = try String(contentsOf: debugLog.invocationLogURL, encoding: .utf8)
            #expect(content.contains("start"))
            #expect(content.contains("prompt=\("プロンプト".utf8.count)"))
            #expect(content.contains("exit=0"))
        }
    }

    /// ストリーミング版でもデバッグログにチャンク受信が残る（進行の生存確認が目的）
    @Test func streamingDebugLogRecordsChunks() async throws {
        try await withTempDir { dir in
            let debugLog = try ClaudeDebugLog(directory: dir, label: "stream")
            let generator = ClaudeCLIGenerator(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '%s\\n' '{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"ok\"}'"],
                debugLogFactory: { debugLog }
            )
            let output = try await generator.generate(prompt: "x") { _ in }
            #expect(output == "ok")

            let content = try String(contentsOf: debugLog.invocationLogURL, encoding: .utf8)
            #expect(content.contains("total="))
            #expect(content.contains("exit=0"))
        }
    }

    /// ログは generate 呼び出しごとに1組作る。generator 使い回し（チャンク並列補正等）で
    /// 複数呼び出しが同じファイルへ混ざった不具合の再発防止
    @Test func createsFreshDebugLogPerGenerateCall() async throws {
        try await withTempDir { dir in
            let counter = PartialCollector()
            let generator = ClaudeCLIGenerator(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo ok"],
                debugLogFactory: {
                    counter.append("called")
                    return try? ClaudeDebugLog(directory: dir, label: "percall")
                }
            )
            _ = try await generator.generate(prompt: "a")
            _ = try await generator.generate(prompt: "b")
            #expect(counter.values.count == 2)
            let logs = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.contains("percall") && !$0.contains("cli") }
            #expect(logs.count == 2)
        }
    }

    /// GUI 起動時の PATH（/usr/bin:/bin のみ）対策と、プロジェクト設定を拾わない空 cwd の契約
    @Test func runsInEmptyTempDirWithExecutableDirOnPath() async throws {
        try await withTempDir { dir in
            let script = dir.appendingPathComponent("probe.sh")
            try "#!/bin/sh\nprintf '%s|%s' \"$PWD\" \"$PATH\"\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

            let generator = ClaudeCLIGenerator(executableURL: script, arguments: [])
            let output = try await generator.generate(prompt: "x")
            let parts = output.split(separator: "|", maxSplits: 1).map(String.init)
            #expect(parts.count == 2)
            #expect(parts[0].contains("otolog-claude-"))
            #expect(parts[1].split(separator: ":").map(String.init).contains(dir.path))
        }
    }

    // MARK: Private

    private final class PartialCollector: @unchecked Sendable {
        // MARK: Internal

        var values: [String] {
            lock.withLock { _values }
        }

        func append(_ value: String) {
            lock.withLock { _values.append(value) }
        }

        // MARK: Private

        private let lock = NSLock()
        private var _values: [String] = []
    }

    private func withTempDir(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }
}
