import Foundation

// MARK: - CommandResult

/// サブプロセスの実行結果。exit code 非0 もエラーではなく結果として返す（意味付けは呼び出し側の責務）。
public struct CommandResult: Sendable {
    public let terminationStatus: Int32
    public let stdout: Data
    public let stderr: Data
}

// MARK: - CommandRunner

/// サブプロセス実行基盤。Process / Pipe / FileHandle の非 Sendable はこのファイル内に閉じ込める。
///
/// デッドロック回避の設計:
/// - stdin はパイプではなく一時ファイルを渡す。書き込み側のブロッキング・SIGPIPE・並行書き込みが不要になる
/// - stdout / stderr は並行にドレインする。片方だけ読むと子がもう片方のパイプ詰まりで止まり相互待ちになる
public enum CommandRunner {
    // MARK: Public

    public static func run(
        executable: URL,
        arguments: [String],
        stdin stdinData: Data,
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(600),
        onStdoutChunk: (@Sendable (Data) -> Void)? = nil
    ) async throws -> CommandResult {
        let stdinURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("otolog-stdin-\(UUID().uuidString)")
        try stdinData.write(to: stdinURL)
        defer { try? FileManager.default.removeItem(at: stdinURL) }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectoryURL { process.currentDirectoryURL = currentDirectoryURL }
        if let environment { process.environment = environment }

        let stdinHandle = try FileHandle(forReadingFrom: stdinURL)
        defer { try? stdinHandle.close() }
        process.standardInput = stdinHandle
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // run() より前に設定する。AsyncStream はバッファするため「先に終了→後から待つ」レースがない
        let (exitStream, exitContinuation) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { finished in
            exitContinuation.yield(finished.terminationStatus)
            exitContinuation.finish()
        }

        do {
            try process.run()
        } catch {
            throw CommandRunnerError.launchFailed(error.localizedDescription)
        }

        let box = ProcessBox(process)
        let outBox = HandleBox(stdoutPipe.fileHandleForReading)
        let errBox = HandleBox(stderrPipe.fileHandleForReading)

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: CommandResult?.self) { group in
                group.addTask {
                    async let stdout = Self.drain(outBox, onChunk: onStdoutChunk)
                    async let stderr = Self.drain(errBox)
                    var status: Int32 = -1
                    for await value in exitStream {
                        status = value
                    }
                    return try await CommandResult(terminationStatus: status, stdout: stdout, stderr: stderr)
                }
                group.addTask {
                    // 番犬: timeout 経過で terminate。自分では結果を返さない
                    try? await Task.sleep(for: timeout)
                    if !Task.isCancelled { box.terminateThenKill(markTimedOut: true) }
                    return nil
                }
                while let item = try await group.next() {
                    guard let result = item else { continue } // 番犬発火。terminate 済みの本体完了を待つ
                    group.cancelAll() // 番犬の sleep を解除
                    try Task.checkCancellation() // キャンセル済みなら結果を捨てて CancellationError
                    if box.didTimeOut { throw CommandRunnerError.timedOut(timeout) }
                    return result
                }
                throw CommandRunnerError.timedOut(timeout) // 本体が結果を返さないのは番犬 kill 後のみ
            }
        } onCancel: {
            box.terminateThenKill(markTimedOut: false)
        }
    }

    // MARK: Private

    /// EOF までチャンク単位で読む。FileHandle.bytes のバイト単位イテレーションは MB 級入力で遅すぎるため、
    /// ブロッキング読みを global queue に逃がす（プロセスは SIGKILL まで含めて必ず死ぬので EOF は保証される）。
    /// onChunk で到着ごとの逐次観測（ライブ進捗表示）ができる
    private static func drain(_ box: HandleBox, onChunk: (@Sendable (Data) -> Void)? = nil) async throws -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var data = Data()
                while true {
                    let chunk = box.handle.availableData
                    guard !chunk.isEmpty else { break } // EOF
                    data.append(chunk)
                    onChunk?(chunk)
                }
                continuation.resume(returning: data)
            }
        }
    }
}

// MARK: - HandleBox

/// FileHandle は Sendable でないが、生成直後にちょうど1つのタスクだけが触る運用をこの型で括る
private final class HandleBox: @unchecked Sendable {
    // MARK: Lifecycle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    // MARK: Internal

    let handle: FileHandle
}

// MARK: - ProcessBox

/// 起動済み Process への操作を terminate / kill / isRunning に限定するラッパ。
/// いずれも下層は kill(2) ベースでスレッド安全
private final class ProcessBox: @unchecked Sendable {
    // MARK: Lifecycle

    init(_ process: Process) {
        self.process = process
    }

    // MARK: Internal

    var didTimeOut: Bool {
        lock.withLock { markedTimedOut }
    }

    /// SIGTERM を送り、grace 経過後もまだ生きていれば SIGKILL で確実に落とす
    func terminateThenKill(afterGrace grace: Duration = .seconds(5), markTimedOut: Bool) {
        if markTimedOut {
            lock.withLock { markedTimedOut = true }
        }
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(grace.components.seconds)) { [process] in
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    // MARK: Private

    private let process: Process
    private let lock = NSLock()
    private var markedTimedOut = false
}

// MARK: - CommandRunnerError

public enum CommandRunnerError: Error, LocalizedError {
    case launchFailed(String)
    case timedOut(Duration)

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(reason):
            "コマンドを起動できませんでした: \(reason)"
        case let .timedOut(timeout):
            "コマンドが\(timeout.components.seconds)秒以内に終了しませんでした"
        }
    }
}
