@preconcurrency import AVFAudio
import Foundation
import Speech

// MARK: - SpeechAnalyzerEngine

/// SpeechAnalyzer（macOS 26 オンデバイス認識）による TranscriptionEngine 実装。
/// RecordingSession から直列に呼ばれる規約のもとで @unchecked Sendable として扱う。
public final class SpeechAnalyzerEngine: TranscriptionEngine, @unchecked Sendable {
    // MARK: Lifecycle

    /// セッション識別情報（sessionID 等）は RecordingSession が発行し start(chunks:context:) で受け取る
    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    // MARK: Public

    public func prepare(
        locale: Locale,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> AVAudioFormat {
        guard SpeechTranscriber.isAvailable else { throw EngineError.transcriberUnavailable }

        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw EngineError.unsupportedLocale(locale.identifier)
        }

        try await AssetInventory.ensureReserved(locale: locale)

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        // installedLocales でゲートしない。volatileResults 等のモジュール構成によっては
        // 追加アセットが要り、不足のまま analyzer.start すると無期限に待つ。
        // 不足が無ければ request は nil になるので常に問い合わせてよい
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
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

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EngineError.noCompatibleAudioFormat
        }
        return format
    }

    public func start(
        chunks: AsyncThrowingStream<AudioChunk, any Error>,
        context: TranscriptionContext
    ) async throws -> AsyncThrowingStream<TranscriptEvent, any Error> {
        guard let transcriber else { throw EngineError.notPrepared }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let (inputSequence, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.inputContinuation = inputContinuation

        let (events, eventContinuation) = AsyncThrowingStream<TranscriptEvent, any Error>.makeStream()
        self.eventContinuation = eventContinuation

        // results はライブ配信型で過去分を再送しないため、analyzer.start より先に購読を張る。
        // 短い入力では解析が購読より先に終わり、結果を取りこぼした挙句シーケンスも終端しない
        startResultsTask(transcriber: transcriber, context: context, eventContinuation: eventContinuation)

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

    private let now: @Sendable () -> Date

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var eventContinuation: AsyncThrowingStream<TranscriptEvent, any Error>.Continuation?
    private var feedTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    /// 入力終端後の確定とイベント列の閉鎖。feedTask と finish() の両方から到達し得るが、
    /// finalize は try? で握り、finish は冪等なので二重実行しても害はない
    private func drainAndFinish() async {
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        Self.trace("finalize returned")
        // results シーケンスの終端に依存せず、イベント列はここで確実に閉じる
        eventContinuation?.finish()
    }

    private func startResultsTask(
        transcriber: SpeechTranscriber,
        context: TranscriptionContext,
        eventContinuation: AsyncThrowingStream<TranscriptEvent, any Error>.Continuation
    ) {
        let now = now
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    Self.trace("result isFinal=\(result.isFinal) len=\(result.text.characters.count)")
                    let event = TranscriberEventMapper.map(
                        text: result.text,
                        isFinal: result.isFinal,
                        context: context,
                        now: now()
                    )
                    if let event {
                        eventContinuation.yield(event)
                    }
                }
                Self.trace("results sequence ended")
                eventContinuation.finish()
            } catch {
                Self.trace("results sequence threw: \(error)")
                eventContinuation.finish(throwing: error)
            }
        }
    }
}

// MARK: - EngineError

public enum EngineError: Error, LocalizedError {
    case transcriberUnavailable
    case unsupportedLocale(String)
    case noCompatibleAudioFormat
    case notPrepared

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
            "prepare(locale:) を先に呼んでください。"
        }
    }
}
