@preconcurrency import AVFAudio
import Foundation
import Speech

// MARK: - SpeechAnalyzerEngine

/// SpeechAnalyzer（macOS 26 オンデバイス認識）による TranscriptionEngine 実装。
/// RecordingSession から直列に呼ばれる規約のもとで @unchecked Sendable として扱うが、
/// 結果の購読はロケールごとに並行するため、裁定まわりだけはロックで守る。
public final class SpeechAnalyzerEngine: TranscriptionEngine, @unchecked Sendable {
    // MARK: Lifecycle

    /// セッション識別情報（sessionID 等）は RecordingSession が発行し start(chunks:context:) で受け取る
    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    // MARK: Public

    public func prepare(
        locales: [Locale],
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> AVAudioFormat {
        guard SpeechTranscriber.isAvailable else { throw EngineError.transcriberUnavailable }
        guard !locales.isEmpty else { throw EngineError.noLocaleRequested }
        // 予約枠はシステム全体で共有される。超えると reserve が静かに失敗して認識が始まらない
        guard locales.count <= AssetInventory.maximumReservedLocales else {
            throw EngineError.tooManyLocales(AssetInventory.maximumReservedLocales)
        }

        let supported = await SpeechTranscriber.supportedLocales
        var built: [Entry] = []
        for locale in locales {
            guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
                throw EngineError.unsupportedLocale(locale.identifier)
            }
            try await AssetInventory.ensureReserved(locale: locale)
            built.append(Entry(
                locale: locale,
                transcriber: SpeechTranscriber(
                    locale: locale,
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults],
                    attributeOptions: [.audioTimeRange]
                )
            ))
        }
        transcribers = built

        // installedLocales でゲートしない。volatileResults 等のモジュール構成によっては
        // 追加アセットが要り、不足のまま analyzer.start すると無期限に待つ。
        // 不足が無ければ request は nil になるので常に問い合わせてよい
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: built.map(\.transcriber)
        ) {
            nonisolated(unsafe) let progress = request.progress
            let progressTask = Task {
                while !Task.isCancelled, !progress.isFinished {
                    onProgress(progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { progressTask.cancel() }
            try await request.downloadAndInstall()
            onProgress(1.0)
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: built.map(\.transcriber)
        ) else {
            throw EngineError.noCompatibleAudioFormat
        }
        return format
    }

    public func start(
        chunks: AsyncThrowingStream<AudioChunk, any Error>,
        context: TranscriptionContext
    ) async throws -> AsyncThrowingStream<TranscriptEvent, any Error> {
        guard !transcribers.isEmpty else { throw EngineError.notPrepared }

        let analyzer = SpeechAnalyzer(modules: transcribers.map(\.transcriber))
        self.analyzer = analyzer
        let (inputSequence, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.inputContinuation = inputContinuation

        let (events, eventContinuation) = AsyncThrowingStream<TranscriptEvent, any Error>.makeStream()
        self.eventContinuation = eventContinuation

        lock.withLock {
            arbiter = LanguageArbiter(candidates: transcribers.map { $0.locale.identifier(.bcp47) })
            hasNarrowed = false
        }

        // results はライブ配信型で過去分を再送しないため、analyzer.start より先に購読を張る。
        // 短い入力では解析が購読より先に終わり、結果を取りこぼした挙句シーケンスも終端しない
        for entry in transcribers {
            startResultsTask(for: entry, context: context, eventContinuation: eventContinuation)
        }

        try await analyzer.start(inputSequence: inputSequence)

        feedTask = Task { [weak self] in
            // キャプチャ側の障害はセッションが再起動で吸収するため、ここでは throw を握って入力を閉じるだけ
            var count = 0
            do {
                for try await chunk in chunks {
                    inputContinuation.yield(AnalyzerInput(buffer: chunk.buffer))
                    count += 1
                }
            } catch {}
            inputContinuation.finish()
            Self.trace("feed ended after \(count) chunks")
            // チャンク列の自然終端（ファイル終端・セッション stop）で残りを確定させる
            await self?.drainAndFinish()
        }
        return events
    }

    public func finish() async {
        inputContinuation?.finish()
        await drainAndFinish()
    }

    // MARK: Internal

    /// OTOLOG_TRACE=1 のときだけ stderr へ内部動作を出す
    static func trace(_ message: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["OTOLOG_TRACE"] == "1" else { return }
        FileHandle.standardError.write(Data("engine: \(message())\n".utf8))
    }

    // MARK: Private

    private struct Entry {
        let locale: Locale
        let transcriber: SpeechTranscriber
    }

    private let now: @Sendable () -> Date
    /// 結果の購読がロケールごとに並行するため、裁定と絞り込みの状態はここで守る
    private let lock = NSLock()

    private var transcribers: [Entry] = []
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var eventContinuation: AsyncThrowingStream<TranscriptEvent, any Error>.Continuation?
    private var feedTask: Task<Void, Never>?
    private var resultsTasks: [Task<Void, Never>] = []
    private var arbiter: LanguageArbiter?
    private var hasNarrowed = false

    /// 入力終端後の確定とイベント列の閉鎖。feedTask と finish() の両方から到達し得るが、
    /// finalize は try? で握り、finish は冪等なので二重実行しても害はない
    private func drainAndFinish() async {
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        Self.trace("finalize returned")
        // 言語が決まらないまま終わったぶんを落とさずに出す
        let remaining = lock.withLock { arbiter?.flush() ?? [] }
        for segment in remaining {
            eventContinuation?.yield(.finalized(segment))
        }
        // results シーケンスの終端に依存せず、イベント列はここで確実に閉じる
        eventContinuation?.finish()
    }

    private func startResultsTask(
        for entry: Entry,
        context: TranscriptionContext,
        eventContinuation: AsyncThrowingStream<TranscriptEvent, any Error>.Continuation
    ) {
        let now = now
        // セグメントには実際に聞き取った認識器のロケールを入れる
        var moduleContext = context
        moduleContext.locale = entry.locale.identifier(.bcp47)

        let task = Task { [weak self] in
            do {
                for try await result in entry.transcriber.results {
                    guard let self else { return }
                    Self.trace("[\(moduleContext.locale)] isFinal=\(result.isFinal) len=\(result.text.characters.count)")
                    guard let event = TranscriberEventMapper.map(
                        text: result.text,
                        isFinal: result.isFinal,
                        context: moduleContext,
                        now: now()
                    ) else { continue }

                    switch event {
                    case let .volatile(text):
                        if let shown = arbitrate(volatile: text, locale: moduleContext.locale) {
                            eventContinuation.yield(.volatile(shown))
                        }
                    case let .finalized(segment):
                        for emitted in arbitrate(final: segment) {
                            eventContinuation.yield(.finalized(emitted))
                        }
                    }
                    narrowIfDecided()
                }
                Self.trace("[\(moduleContext.locale)] results ended")
            } catch {
                // 候補の1つが落ちても、残りが生きていれば認識は続く。ここでは列を閉じない
                Self.trace("[\(moduleContext.locale)] results threw: \(error)")
            }
        }
        resultsTasks.append(task)
    }

    private func arbitrate(final segment: TranscriptSegment) -> [TranscriptSegment] {
        lock.withLock {
            guard arbiter != nil else { return [segment] }
            return arbiter!.accept(segment)
        }
    }

    private func arbitrate(volatile text: String, locale: String) -> String? {
        lock.withLock {
            guard arbiter != nil else { return text }
            return arbiter!.acceptVolatile(text: text, locale: locale)
        }
    }

    /// 話者の言語が決まったら勝者だけに絞る。負けた認識器を回し続ける意味はない
    private func narrowIfDecided() {
        let winner: SpeechTranscriber? = lock.withLock {
            guard !hasNarrowed, transcribers.count > 1,
                  let decided = arbiter?.decidedLocale,
                  let entry = transcribers.first(where: { $0.locale.identifier(.bcp47) == decided })
            else { return nil }
            hasNarrowed = true
            return entry.transcriber
        }
        guard let winner, let analyzer else { return }
        Task {
            // 失敗しても全モジュールのまま動き続けるだけなので握る
            try? await analyzer.setModules([winner])
            Self.trace("narrowed to single module")
        }
    }
}

// MARK: - EngineError

public enum EngineError: Error, LocalizedError {
    case transcriberUnavailable
    case unsupportedLocale(String)
    case noCompatibleAudioFormat
    case notPrepared
    case noLocaleRequested
    case tooManyLocales(Int)

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case .transcriberUnavailable:
            "SpeechTranscriber はこのデバイスで利用できません。"
        case let .unsupportedLocale(identifier):
            "ロケール \"\(identifier)\" は音声認識に対応していません。"
        case .noCompatibleAudioFormat:
            "音声認識に使えるオーディオフォーマットがありません。"
        case .notPrepared:
            "prepare(locales:) を先に呼んでください。"
        case .noLocaleRequested:
            "認識する言語が指定されていません。"
        case let .tooManyLocales(maximum):
            "同時に扱える言語は \(maximum) 個までです。"
        }
    }
}
