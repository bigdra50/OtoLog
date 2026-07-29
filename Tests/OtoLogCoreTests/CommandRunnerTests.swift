import Foundation
@testable import OtoLogCore
import Testing

struct CommandRunnerTests {
    /// 64KB のパイプバッファを大きく超える入力でもデッドロックしない契約（stdin は一時ファイル渡し）
    @Test func echoesLargeStdinThroughCat() async throws {
        let payload = String(repeating: "あいうえお12345\n", count: 65536)
        let result = try await CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], stdin: Data(payload.utf8)
        )
        #expect(result.terminationStatus == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == payload)
    }

    /// exit code 非0 はエラーではなく結果として返す（意味付けは呼び出し側の責務）
    @Test func capturesStderrAndNonZeroExit() async throws {
        let result = try await CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo out; echo err 1>&2; exit 3"], stdin: Data()
        )
        #expect(result.terminationStatus == 3)
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("out"))
        #expect(String(decoding: result.stderr, as: UTF8.self).contains("err"))
    }

    @Test(.timeLimit(.minutes(1))) func timesOutAndTerminatesProcess() async {
        await #expect(throws: CommandRunnerError.self) {
            _ = try await CommandRunner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                stdin: Data(), timeout: .milliseconds(300)
            )
        }
    }

    /// Task.cancel がプロセス terminate まで届き、結果を返さず CancellationError になる契約
    @Test(.timeLimit(.minutes(1))) func cancellationTerminatesProcessAndThrowsCancellationError() async throws {
        let task = Task {
            try await CommandRunner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], stdin: Data()
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func throwsLaunchFailedForMissingExecutable() async {
        await #expect(throws: CommandRunnerError.self) {
            _ = try await CommandRunner.run(
                executable: URL(fileURLWithPath: "/nonexistent/binary-\(UUID())"), arguments: [], stdin: Data()
            )
        }
    }

    @Test func passesArgumentsAndEnvironment() async throws {
        let result = try await CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' \"$OTOLOG_TEST_VALUE\""],
            stdin: Data(),
            environment: ["OTOLOG_TEST_VALUE": "injected"]
        )
        #expect(String(decoding: result.stdout, as: UTF8.self) == "injected")
    }
}
