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
        timeout: Duration = .seconds(1800), // 補正は入力量に比例して長い。ハングはライブ表示で分かるため保険として長め
        // 既定で環境変数駆動 = 全呼び出し経路が対象。generate ごとに呼び、1呼び出し1ログ組を保つ
        // （generator 使い回しの並列 generate が同じファイルへ混ざらないよう factory で受ける）
        debugLogFactory: @escaping @Sendable () -> ClaudeDebugLog? = { ClaudeDebugLog.fromEnvironment() }
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
        self.debugLogFactory = debugLogFactory
    }

    // MARK: Public

    /// ヘッドレス後処理に必要な設定の明示。--setting-sources "" と併用する。
    /// --settings 指定はユーザー settings.json の env を復活させる副作用があるため（実測）、
    /// 遮断だけでは足りず thinking と effort をここで明示上書きする。
    /// - alwaysThinkingEnabled: false — thinking が max_tokens 予算を食うと全文書き直し系の
    ///   本文が1ターンに収まらず、自動継続で所要時間が数倍〜数十倍化する（12分/ターン × 3回+ の実測）
    /// - CLAUDE_CODE_EFFORT_LEVEL: high — effort max は thinking 無効の opus で 400 になる。
    ///   後処理は書き写し・整形系が主のため high で足りる。--effort フラグは env に負けるため不可
    public static let overrideSettingsJSON =
        #"{"alwaysThinkingEnabled": false, "env": {"CLAUDE_CODE_EFFORT_LEVEL": "high"}}"#

    /// Claude Code の既定エージェントプロンプト（コーディング・ツール指示の長文）を置き換える。
    /// 後処理には無関係な指示の混入を避け、入力トークンも減らす
    public static let systemPrompt =
        "音声文字起こしログを後処理するツールの内部エンジンとして、与えられた指示に厳密に従い、結果のテキストのみを出力する。"

    /// 安全側に倒した既定フラグ。
    /// --tools "" はツール全無効 = ログ由来のプロンプトインジェクションでもテキスト出力しかできない。
    /// --setting-sources "" でユーザー/プロジェクト settings.json（hooks・thinking・effort 等）を
    /// 継承しない = 挙動が実行環境の個人設定に依存しない。
    /// --model は付けずユーザーの CLI 既定に従う。--bare は OAuth 認証を読まなくなるため使わない
    public static let defaultArguments = [
        "-p", "--output-format", "text", "--tools", "",
        "--no-session-persistence", "--disable-slash-commands",
        "--setting-sources", "",
        "--settings", ClaudeCLIGenerator.overrideSettingsJSON,
        "--system-prompt", ClaudeCLIGenerator.systemPrompt,
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

        let debugLog = debugLogFactory()
        let runArguments = Self.argumentsAddingDebugFile(to: arguments, debugLog: debugLog)
        debugLog?.logStart(arguments: runArguments, promptBytes: prompt.utf8.count)
        let result: CommandResult
        do {
            result = try await CommandRunner.run(
                executable: executableURL,
                arguments: runArguments,
                stdin: Data(prompt.utf8),
                currentDirectoryURL: workDir,
                environment: environment,
                timeout: timeout,
                onStdoutChunk: { [debugLog] chunk in debugLog?.logChunk(bytes: chunk.count) }
            )
        } catch {
            debugLog?.logError(error.localizedDescription)
            throw error
        }
        debugLog?.logFinish(
            terminationStatus: result.terminationStatus,
            stdoutBytes: result.stdout.count,
            stderrTail: Self.tail(of: result.stderr)
        )

        guard result.terminationStatus == 0 else {
            // claude -p は API エラーを stdout（stream-json の result）へ出すことがあるため、
            // stderr が空なら stdout 末尾を診断に使う
            let stderrTail = Self.tail(of: result.stderr)
            throw ClaudeCLIGeneratorError.nonZeroExit(
                code: result.terminationStatus,
                stderr: stderrTail.isEmpty ? Self.tail(of: result.stdout) : stderrTail
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
        let debugLog = debugLogFactory()
        let runArguments = Self.argumentsAddingDebugFile(
            to: Self.streamingArguments(from: arguments), debugLog: debugLog
        )
        debugLog?.logStart(arguments: runArguments, promptBytes: prompt.utf8.count)
        let result: CommandResult
        do {
            result = try await CommandRunner.run(
                executable: executableURL,
                arguments: runArguments,
                stdin: Data(prompt.utf8),
                currentDirectoryURL: workDir,
                environment: environment,
                timeout: timeout,
                onStdoutChunk: { [debugLog] chunk in
                    parser.consume(chunk)
                    debugLog?.logChunk(bytes: chunk.count)
                }
            )
        } catch {
            debugLog?.logError(error.localizedDescription)
            throw error
        }
        debugLog?.logFinish(
            terminationStatus: result.terminationStatus,
            stdoutBytes: result.stdout.count,
            stderrTail: Self.tail(of: result.stderr)
        )

        guard result.terminationStatus == 0 else {
            // claude -p は API エラーを stdout（stream-json の result）へ出すことがあるため、
            // stderr が空なら stdout 末尾を診断に使う
            let stderrTail = Self.tail(of: result.stderr)
            throw ClaudeCLIGeneratorError.nonZeroExit(
                code: result.terminationStatus,
                stderr: stderrTail.isEmpty ? Self.tail(of: result.stdout) : stderrTail
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
    private let debugLogFactory: @Sendable () -> ClaudeDebugLog?

    /// stderr は診断用に末尾だけ保持する（未ログイン・context 超過などの本文は末尾に出る）
    private static func tail(of data: Data, maxCharacters: Int = 2000) -> String {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.suffix(maxCharacters))
    }

    /// デバッグ有効時のみ --debug-file を足す（claude CLI 内部ログの取得。implicitly enables debug mode）
    private static func argumentsAddingDebugFile(to arguments: [String], debugLog: ClaudeDebugLog?) -> [String] {
        guard let debugLog else { return arguments }
        return arguments + ["--debug-file", debugLog.cliDebugLogURL.path]
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
