import Foundation
@testable import OtoLogCore
import Testing

struct ClaudeCLIGeneratorTests {
    // MARK: Internal

    /// 安全フラグの契約: ツール全無効・セッション残さない・スラッシュコマンド無効。
    /// 変更は claude CLI 側の互換確認（mise run test:claude）とセットで行う
    @Test func defaultArgumentsArePinned() {
        #expect(ClaudeCLIGenerator.defaultArguments == [
            "-p", "--output-format", "text", "--tools", "",
            "--no-session-persistence", "--disable-slash-commands",
        ])
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

    private func withTempDir(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }
}
