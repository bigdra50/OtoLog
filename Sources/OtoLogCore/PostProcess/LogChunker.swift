import Foundation

/// 長いログ本文を行境界で上限文字数以下のチャンクへ分割する。
/// 全文書き直し系タスク（correct）の出力が LLM の1ターン上限を超えると
/// 自動継続で所要時間が際限なく延びるため、入力側を出力が収まるサイズに割る。
public enum LogChunker {
    /// 行（= 1確定セグメント）の途中では切らない。1行が単独で上限を超える場合はその行だけのチャンクにする。
    /// チャンクを "\n" で結合すると元の logBody に戻る（情報を落とさない契約）
    public static func split(logBody: String, maxCharacters: Int) -> [String] {
        guard !logBody.isEmpty else { return [] }
        var chunks: [String] = []
        var currentLines: [String] = []
        var currentCount = 0

        for line in logBody.components(separatedBy: "\n") {
            // +1 は結合時の改行分
            let addition = currentLines.isEmpty ? line.count : line.count + 1
            if !currentLines.isEmpty, currentCount + addition > maxCharacters {
                chunks.append(currentLines.joined(separator: "\n"))
                currentLines = []
                currentCount = 0
            }
            currentLines.append(line)
            currentCount += currentLines.count == 1 ? line.count : line.count + 1
        }
        if !currentLines.isEmpty {
            chunks.append(currentLines.joined(separator: "\n"))
        }
        return chunks
    }
}
