import AVFAudio
import Foundation
@testable import OtoLogCore
import Speech
import Testing

// MARK: - SpeechAnalyzerEngineIntegrationTests

/// 実 SpeechAnalyzer を使う統合テスト。OTOLOG_INTEGRATION=1 のときだけ実行される。
/// 初回はロケールモデルのダウンロードが走るためネットワークが必要。
/// AssetInventory へ並行アクセスするとハングするため必ず直列で実行する。
@Suite(.serialized, .timeLimit(.minutes(10)), .enabled(if: ProcessInfo.processInfo.environment["OTOLOG_INTEGRATION"] == "1")) struct SpeechAnalyzerEngineIntegrationTests {
    // MARK: Internal

    @Test func ensureReservedIsIdempotent() async throws {
        let ja = Locale(identifier: "ja-JP")
        try await AssetInventory.ensureReserved(locale: ja)
        try await AssetInventory.ensureReserved(locale: ja)
        let reserved = await AssetInventory.reservedLocales
        #expect(reserved.contains { $0.identifier(.bcp47) == "ja-JP" })
    }

    @Test func transcribesJapaneseSayFixtureEndToEnd() async throws {
        let fixture = try makeSayFixture(voice: "Kyoko", text: "こんにちは。これは統合テストです。")
        defer { try? FileManager.default.removeItem(at: fixture) }

        let finals = try await transcribe(fixture, localeIdentifier: "ja-JP")

        #expect(!finals.isEmpty)
        let combined = normalize(finals.map(\.text).joined())
        #expect(combined.contains("統合テスト"))
        #expect(finals.first?.audioStart != nil)
        #expect(finals.allSatisfy { $0.locale == "ja-JP" && $0.source == .system })
    }

    @Test func transcribesEnglishSayFixtureEndToEnd() async throws {
        guard try voiceAvailable("Samantha") else { return }
        let fixture = try makeSayFixture(voice: "Samantha", text: "Hello. This is an integration test.")
        defer { try? FileManager.default.removeItem(at: fixture) }

        let finals = try await transcribe(fixture, localeIdentifier: "en-US")

        let combined = normalize(finals.map(\.text).joined()).lowercased()
        #expect(combined.contains("integrationtest"))
    }

    /// 候補を複数渡すと話者の言語が選ばれ、その言語の結果だけが残る。
    /// 判定がつくまでの発話も落とさずに出てくることまで見る
    @Test func detectsJapaneseAmongCandidates() async throws {
        let fixture = try makeSayFixture(
            voice: "Kyoko",
            text: "本日はボクセルレンダリングの大規模化についてお話しします。オクツリーは破綻します。"
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let finals = try await transcribe(fixture, localeIdentifiers: ["en-US", "ja-JP"])

        #expect(!finals.isEmpty)
        #expect(finals.allSatisfy { $0.locale == "ja-JP" })
        // 冒頭（判定前に確定した分）が欠けていないこと
        #expect(normalize(finals.map(\.text).joined()).contains("本日"))
    }

    @Test func detectsEnglishAmongCandidates() async throws {
        guard try voiceAvailable("Samantha") else { return }
        let fixture = try makeSayFixture(
            voice: "Samantha",
            text: "Today I want to talk about how we approach voxel rendering at scale, and why the naive octree approach breaks down."
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let finals = try await transcribe(fixture, localeIdentifiers: ["ja-JP", "en-US"])

        #expect(!finals.isEmpty)
        // 候補の先頭が ja-JP でも、話者が英語なら英語が選ばれる
        #expect(finals.allSatisfy { $0.locale == "en-US" })
        #expect(normalize(finals.map(\.text).joined()).lowercased().contains("today"))
    }

    /// 予約枠を超える指定は始める前に弾く。黙って認識が始まらないより明示エラーがよい
    @Test func rejectsMoreLocalesThanReservationLimit() async throws {
        let engine = SpeechAnalyzerEngine()
        let tooMany = (0...AssetInventory.maximumReservedLocales)
            .map { _ in Locale(identifier: "en-US") }

        await #expect(throws: EngineError.self) {
            _ = try await engine.prepare(locales: tooMany, onProgress: { _ in })
        }
    }

    // MARK: Private

    private func transcribe(_ url: URL, localeIdentifier: String) async throws -> [TranscriptSegment] {
        try await transcribe(url, localeIdentifiers: [localeIdentifier])
    }

    private func transcribe(_ url: URL, localeIdentifiers: [String]) async throws -> [TranscriptSegment] {
        let localeIdentifier = localeIdentifiers[0]
        let engine = SpeechAnalyzerEngine()
        let format = try await engine.prepare(
            locales: localeIdentifiers.map { Locale(identifier: $0) }, onProgress: { _ in }
        )
        let capture = FileCaptureSource(url: url)
        let chunks = try await capture.start(targetFormat: format)
        let context = TranscriptionContext(
            locale: localeIdentifier, source: .system,
            sessionID: UUID(), sessionStartedAt: Date()
        )
        let events = try await engine.start(chunks: chunks, context: context)

        // ファイル終端 → エンジンが自動確定 → イベント列の自然終端まで消費する。
        // finish() をここで呼ぶと供給中の入力を切断してしまうので呼ばない
        var finals: [TranscriptSegment] = []
        do {
            for try await event in events {
                if case let .finalized(segment) = event {
                    finals.append(segment)
                }
            }
        } catch {}
        return finals
    }

    private func makeSayFixture(voice: String, text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("otolog-fixture-\(UUID().uuidString).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return url
    }

    private func voiceAvailable(_ voice: String) throws -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "?"]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).contains(voice)
    }

    /// TTS→ASR の往復で句読点・空白は揺れるため、除去してから含有判定する
    private func normalize(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
            .components(separatedBy: .punctuationCharacters).joined()
    }
}
