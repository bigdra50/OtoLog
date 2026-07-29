import Foundation
@testable import OtoLogCore
import Testing

struct JSONLCoderTests {
    /// 時刻はミリ秒精度で保存する契約（ISO8601 withFractionalSeconds）
    let segment = TranscriptSegment(
        text: "こんにちは",
        audioStart: 1.5,
        audioEnd: 3.25,
        finalizedAt: Date(timeIntervalSince1970: 1_785_297_600.500),
        locale: "ja-JP",
        source: .system,
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        sessionStartedAt: Date(timeIntervalSince1970: 1_785_297_540.000)
    )

    @Test func encodesDeterministicSingleLine() throws {
        let line = try JSONLCoder.encodeLine(segment)
        #expect(!line.contains("\n"))
        #expect(line == #"{"audioEnd":3.25,"audioStart":1.5,"finalizedAt":"2026-07-29T04:00:00.500Z","locale":"ja-JP","sessionID":"00000000-0000-0000-0000-000000000001","sessionStartedAt":"2026-07-29T03:59:00.000Z","source":"system","text":"こんにちは"}"#)
    }

    @Test func roundTripsThroughEncodeAndDecode() throws {
        let line = try JSONLCoder.encodeLine(segment)
        let decoded = try JSONLCoder.decodeLine(line)
        #expect(decoded == segment)
    }

    @Test func escapesNewlinesAndQuotesIntoSingleLine() throws {
        var tricky = segment
        tricky.text = "1行目\n\"引用\"付き"
        let line = try JSONLCoder.encodeLine(tricky)
        #expect(!line.contains("\n"))
        let decoded = try JSONLCoder.decodeLine(line)
        #expect(decoded.text == "1行目\n\"引用\"付き")
    }

    @Test func omitsNilAudioRange() throws {
        var noRange = segment
        noRange.audioStart = nil
        noRange.audioEnd = nil
        let line = try JSONLCoder.encodeLine(noRange)
        #expect(!line.contains("audioStart"))
        #expect(!line.contains("audioEnd"))
        let decoded = try JSONLCoder.decodeLine(line)
        #expect(decoded == noRange)
    }
}
