import AVFAudio
import Foundation
import OtoLogCore

// FileCaptureSource → SpeechAnalyzerEngine の統合検証・デバッグ用 CLI。
// swift test の統合スイートと同じ経路を、単体で素早く観察できる（OTOLOG_TRACE=1 で内部トレース）。
// 使い方: otolog-devtool <audio-file> [locale]
//         otolog-devtool export-templates <dir>
//         otolog-devtool migrate-daily <dir>
//         otolog-devtool run-playbook <dir> <sessionDirName> [playbookID]

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("""
    usage: otolog-devtool <audio-file> [locale]
           otolog-devtool export-templates <dir>
           otolog-devtool migrate-daily <dir>
           otolog-devtool run-playbook <dir> <sessionDirName> [playbookID]

    """.utf8))
    exit(64)
}

// 組み込みテンプレートの md 書き出し（スキル同梱 templates/ の再生成に使う）
if args[1] == "export-templates" {
    guard args.count >= 3 else {
        FileHandle.standardError.write(Data("usage: otolog-devtool export-templates <dir>\n".utf8))
        exit(64)
    }
    let urls = try TemplateExporter.export(to: URL(fileURLWithPath: args[2], isDirectory: true))
    for url in urls {
        print(url.path)
    }
    exit(0)
}

// 既存の correct.md から修正辞書を一括学習する（初期シード・再構築用）
if args[1] == "learn-corrections" {
    guard args.count >= 3 else {
        FileHandle.standardError.write(Data("usage: otolog-devtool learn-corrections <dir>\n".utf8))
        exit(64)
    }
    let directory = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath, isDirectory: true)
    let reader = TranscriptReader(directory: directory, timeZone: .current)
    let store = CorrectionDictionaryStore()
    let builder = PromptBuilder(timeZone: .current)
    var total = 0
    for session in reader.availableSessions() {
        let correctURL = directory
            .appendingPathComponent(session.directoryName)
            .appendingPathComponent("correct.md")
        guard let raw = try? String(contentsOf: correctURL, encoding: .utf8),
              let corrected = TimestampedLogParser.parse(PostProcessRunner.stripProvenanceHeader(raw)),
              let segments = try? reader.segments(in: session),
              let original = TimestampedLogParser.parse(builder.logBody(from: segments))
        else { continue }
        let pairs = CorrectionExtractor.pairs(original: original, corrected: corrected)
        guard !pairs.isEmpty else { continue }
        try store.record(pairs, now: Date())
        total += pairs.count
        print("learned \(pairs.count) pairs from \(session.displayName)")
    }
    print("total: \(total) pairs -> \(CorrectionDictionaryStore.defaultFileURL.path)")
    exit(0)
}

// 内容ベースのプレイブック自動判定を単体で試す（検証用）
if args[1] == "classify" {
    guard args.count >= 4 else {
        FileHandle.standardError.write(Data("usage: otolog-devtool classify <dir> <sessionDirName>\n".utf8))
        exit(64)
    }
    let directory = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath, isDirectory: true)
    let reader = TranscriptReader(directory: directory, timeZone: .current)
    guard let session = reader.availableSessions().first(where: { $0.directoryName == args[3] }) else {
        FileHandle.standardError.write(Data("セッションが見つかりません: \(args[3])\n".utf8))
        exit(66)
    }
    let claudePath = ProcessInfo.processInfo.environment["OTOLOG_CLAUDE"] ?? "~/.local/bin/claude"
    let classifier = SessionClassifier(
        saveDirectory: directory,
        timeZone: .current,
        generator: ClaudeCLIGenerator(
            executableURL: URL(fileURLWithPath: (claudePath as NSString).expandingTildeInPath),
            arguments: ClaudeCLIGenerator.arguments(model: .haiku, allowWebResearch: false)
        )
    )
    let selected = try await classifier.classify(session: session, candidates: PlaybookStore().loadPlaybooks())
    print(selected?.id ?? "none")
    exit(0)
}

// プレイブックをヘッドレスで実行する（検証・自動化用）。
// claude のパスは環境変数 OTOLOG_CLAUDE で上書きできる（既定 ~/.local/bin/claude）
if args[1] == "run-playbook" {
    guard args.count >= 4 else {
        FileHandle.standardError.write(
            Data("usage: otolog-devtool run-playbook <dir> <sessionDirName> [playbookID]\n".utf8)
        )
        exit(64)
    }
    let directory = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath, isDirectory: true)
    let sessionName = args[3]
    let playbookID = args.count >= 5 ? args[4] : "lecture"

    let reader = TranscriptReader(directory: directory, timeZone: .current)
    guard let session = reader.availableSessions().first(where: { $0.directoryName == sessionName }) else {
        FileHandle.standardError.write(Data("セッションが見つかりません: \(sessionName)\n".utf8))
        exit(66)
    }
    guard let playbook = PlaybookStore().loadPlaybooks().first(where: { $0.id == playbookID }) else {
        FileHandle.standardError.write(Data("プレイブックが見つかりません: \(playbookID)\n".utf8))
        exit(66)
    }
    let claudePath = ProcessInfo.processInfo.environment["OTOLOG_CLAUDE"] ?? "~/.local/bin/claude"
    let executableURL = URL(fileURLWithPath: (claudePath as NSString).expandingTildeInPath)

    let runner = PipelineRunner(
        saveDirectory: directory,
        timeZone: .current,
        generatorFactory: { task in
            ClaudeCLIGenerator(
                executableURL: executableURL,
                arguments: ClaudeCLIGenerator.arguments(
                    model: task.model, allowWebResearch: task.allowsWebResearch
                ),
                timeout: task.allowsWebResearch ? .seconds(900) : .seconds(600)
            )
        }
    )
    print("run: \(playbook.displayName) → \(session.displayName)")
    for await event in await runner.run(playbook: playbook, session: session) {
        switch event {
        case let .taskStateChanged(taskID, state):
            let suffix = state.error.map { " (\($0))" } ?? ""
            print("\(taskID): \(state.status.rawValue)\(suffix)")
        case let .finished(done, failed, skipped):
            print("finished: done=\(done) failed=\(failed) skipped=\(skipped)")
            exit(failed > 0 ? 1 : 0)
        }
    }
    exit(0)
}

// 旧フラット構造のセッションを日付フォルダ階層へ移動する
if args[1] == "migrate-structure" {
    guard args.count >= 3 else {
        FileHandle.standardError.write(Data("usage: otolog-devtool migrate-structure <dir>\n".utf8))
        exit(64)
    }
    let directory = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath, isDirectory: true)
    let migrated = try StructureMigrationTool(timeZone: .current).migrate(directory: directory)
    if migrated.isEmpty {
        print("移行対象はありません（旧フラット構造のセッションが見つからないか、移行済みです）")
    }
    for ref in migrated {
        print("moved: \(ref.directoryName)")
    }
    exit(0)
}

// 旧日次形式（YYYY-MM-DD.jsonl）をセッションディレクトリへ変換する
if args[1] == "migrate-daily" {
    guard args.count >= 3 else {
        FileHandle.standardError.write(Data("usage: otolog-devtool migrate-daily <dir>\n".utf8))
        exit(64)
    }
    let directory = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath, isDirectory: true)
    let migrated = try DailyMigrationTool(timeZone: .current).migrate(directory: directory)
    if migrated.isEmpty {
        print("変換対象はありません（旧日次 jsonl が見つからないか、変換済みです）")
    }
    for ref in migrated {
        print("migrated: \(ref.directoryName)")
    }
    exit(0)
}

let url = URL(fileURLWithPath: args[1])
let localeIdentifier = args.count >= 3 ? args[2] : "ja-JP"

let engine = SpeechAnalyzerEngine()
let format = try await engine.prepare(locale: Locale(identifier: localeIdentifier)) { progress in
    FileHandle.standardError.write(Data(String(format: "downloading model: %.0f%%\n", progress * 100).utf8))
}

FileHandle.standardError.write(Data("prepared: \(format)\n".utf8))

func trace(_ message: String) {
    FileHandle.standardError.write(Data("trace: \(message)\n".utf8))
}

let capture = FileCaptureSource(url: url)
let chunks = try await capture.start(targetFormat: format)
trace("capture started")
let context = TranscriptionContext(
    locale: localeIdentifier,
    source: .system,
    sessionID: UUID(),
    sessionStartedAt: Date()
)
let events = try await engine.start(chunks: chunks, context: context)
trace("engine started")

let collector = Task { () -> [String] in
    var texts: [String] = []
    do {
        for try await event in events {
            if case let .finalized(segment) = event {
                texts.append(segment.text)
            }
        }
    } catch {}
    return texts
}

/// ファイル終端 → feed 終了 → エンジンが自動確定してイベント列が閉じるのを待つ
let texts = await collector.value
trace("collector done")
print(texts.joined(separator: "\n"))
