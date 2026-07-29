import Foundation

// MARK: - ClaudeCLIGenerator

/// claude -p をサブプロセスとして呼ぶ TextGenerator 実装。
/// プロンプトは stdin で渡す（引数長制限 ARG_MAX の回避）。
/// ストリーミング版は stream-json でデルタ（本文・thinking）を逐次観測できる。
public struct ClaudeCLIGenerator: StreamingTextGenerator {
    // MARK: Lifecycle

    public init(
        executableURL: URL,
        arguments: [String] = ClaudeCLIGenerator.defaultArguments,
        timeout: Duration = .seconds(600)
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
    }

    // MARK: Public

    /// 安全側に倒した既定フラグ。
    /// --tools "" はツール全無効 = ログ由来のプロンプトインジェクションでもテキスト出力しかできない。
    /// --model は付けずユーザーの CLI 既定に従う。--bare は認証を読まなくなるため使わない
    public static let defaultArguments = [
        "-p", "--output-format", "text", "--tools", "",
        "--no-session-persistence", "--disable-slash-commands",
    ]

    public func generate(prompt: String) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ClaudeCLIGeneratorError.executableNotFound(path: executableURL.path)
        }

        // 空の一時ディレクトリを cwd にする。保存先が git リポジトリ内でも
        // プロジェクト設定・CLAUDE.md・hooks を拾わないため
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("otolog-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // GUI 起動時の PATH は /usr/bin:/bin:/usr/sbin:/sbin のみのため、実行ファイルのディレクトリを足す
        var environment = ProcessInfo.processInfo.environment
        let binDir = executableURL.deletingLastPathComponent().path
        environment["PATH"] = ((environment["PATH"].map { "\($0):" }) ?? "") + binDir

        let result = try await CommandRunner.run(
            executable: executableURL,
            arguments: arguments,
            stdin: Data(prompt.utf8),
            currentDirectoryURL: workDir,
            environment: environment,
            timeout: timeout
        )

        guard result.terminationStatus == 0 else {
            throw ClaudeCLIGeneratorError.nonZeroExit(
                code: result.terminationStatus,
                stderr: Self.tail(of: result.stderr)
            )
        }
        let output = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw ClaudeCLIGeneratorError.emptyOutput
        }
        return output
    }

    /// ストリーミング版: stream-json のデルタ（本文・thinking）を onPartial へ逐次流し、
    /// 最終テキストは result イベントから取り出す
    public func generate(
        prompt: String,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ClaudeCLIGeneratorError.executableNotFound(path: executableURL.path)
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("otolog-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        var environment = ProcessInfo.processInfo.environment
        let binDir = executableURL.deletingLastPathComponent().path
        environment["PATH"] = ((environment["PATH"].map { "\($0):" }) ?? "") + binDir

        let parser = StreamEventParser(onPartial: onPartial)
        let result = try await CommandRunner.run(
            executable: executableURL,
            arguments: Self.streamingArguments(from: arguments),
            stdin: Data(prompt.utf8),
            currentDirectoryURL: workDir,
            environment: environment,
            timeout: timeout,
            onStdoutChunk: { parser.consume($0) }
        )

        guard result.terminationStatus == 0 else {
            throw ClaudeCLIGeneratorError.nonZeroExit(
                code: result.terminationStatus,
                stderr: Self.tail(of: result.stderr)
            )
        }
        let output = parser.finalResult(fallbackStdout: result.stdout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw ClaudeCLIGeneratorError.emptyOutput
        }
        return output
    }

    // MARK: Internal

    /// --output-format text を stream-json 一式へ差し替える（テスト注入等で text 指定が無ければそのまま）
    static func streamingArguments(from arguments: [String]) -> [String] {
        guard let index = arguments.firstIndex(of: "--output-format"),
              index + 1 < arguments.count, arguments[index + 1] == "text"
        else { return arguments }
        var result = arguments
        result.replaceSubrange(
            index...index + 1,
            with: ["--output-format", "stream-json", "--include-partial-messages", "--verbose"]
        )
        return result
    }

    // MARK: Private

    private let executableURL: URL
    private let arguments: [String]
    private let timeout: Duration

    /// stderr は診断用に末尾だけ保持する（未ログイン・context 超過などの本文は末尾に出る）
    private static func tail(of data: Data, maxCharacters: Int = 2000) -> String {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.suffix(maxCharacters))
    }
}

// MARK: - ClaudeCLIGeneratorError

public enum ClaudeCLIGeneratorError: Error, LocalizedError {
    case executableNotFound(path: String)
    case nonZeroExit(code: Int32, stderr: String)
    case emptyOutput

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case let .executableNotFound(path):
            "claude が見つかりません: \(path)（設定でパスを確認してください）"
        case let .nonZeroExit(code, stderr):
            "claude が失敗しました（exit \(code)）: \(stderr)"
        case .emptyOutput:
            "生成結果が空でした"
        }
    }
}
