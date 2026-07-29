import Foundation
@testable import OtoLogCore
import Testing

/// 長いログ本文を行境界で分割するチャンカーの仕様。
/// 1ターンの出力上限を超える全文書き直し（correct）が自動継続で際限なく延びる問題への対策
struct LogChunkerTests {
    @Test func emptyBodyYieldsNoChunks() {
        #expect(LogChunker.split(logBody: "", maxCharacters: 100) == [])
    }

    @Test func bodyWithinLimitStaysSingleChunk() {
        let body = "[13:00:00] 一行目\n[13:00:05] 二行目"
        #expect(LogChunker.split(logBody: body, maxCharacters: 100) == [body])
    }

    /// 行の途中では切らない（セグメント = 発話単位を壊さない契約）
    @Test func splitsOnLineBoundaries() {
        let lines = (1...4).map { "[13:00:0\($0)] 本文\($0)" }
        let body = lines.joined(separator: "\n")
        let oneLine = lines[0].count
        // 2行分ちょうどが上限 → 2行 + 2行 に割れる
        let chunks = LogChunker.split(logBody: body, maxCharacters: oneLine * 2 + 1)
        #expect(chunks == [
            lines[0] + "\n" + lines[1],
            lines[2] + "\n" + lines[3],
        ])
    }

    /// 分割しても情報は失わない（結合すると元に戻る）
    @Test func chunksJoinBackToOriginal() {
        let body = (1...50).map { "[13:00:\(String(format: "%02d", $0))] セグメント\($0)の本文です" }
            .joined(separator: "\n")
        let chunks = LogChunker.split(logBody: body, maxCharacters: 120)
        #expect(chunks.count > 1)
        #expect(chunks.joined(separator: "\n") == body)
        #expect(chunks.allSatisfy { $0.count <= 120 })
    }

    /// 1行が上限を超える場合はその行単独のチャンクにする（行は壊さない）
    @Test func oversizedLineBecomesItsOwnChunk() {
        let huge = "[13:00:00] " + String(repeating: "あ", count: 200)
        let body = "[12:59:59] 短い\n\(huge)\n[13:00:01] 短い2"
        let chunks = LogChunker.split(logBody: body, maxCharacters: 50)
        #expect(chunks == ["[12:59:59] 短い", huge, "[13:00:01] 短い2"])
    }
}
