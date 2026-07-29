import Foundation

/// 長いログ本文を行境界で上限文字数以下のチャンクへ分割する。
/// 全文書き直し系タスク（correct）の出力が LLM の1ターン上限を超えると
/// 自動継続で所要時間が際限なく延びるため、入力側を出力が収まるサイズに割る。
public enum LogChunker {
    // MARK: Public

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

    /// チャンク補正の出力から、入力チャンクに存在しないタイムスタンプの行を除く。
    /// モデルは指示に反して前置き・後書きの説明文を混ぜることがあり、時刻付きに偽装される場合すらある。
    /// 時刻は補正対象外のため「入力に存在するタイムスタンプの行だけが正」を不変条件として使える。
    /// フィルタで全行消える場合（出力形式が想定外）は、情報を失うより元の出力をそのまま返す
    public static func filterToInputTimestamps(output: String, inputChunk: String) -> String {
        let inputTimes = Set(inputChunk.components(separatedBy: "\n").compactMap(timestamp(of:)))
        let kept = output.components(separatedBy: "\n").filter { line in
            guard let time = timestamp(of: line) else { return false }
            return inputTimes.contains(time)
        }
        guard !kept.isEmpty else { return output }
        return kept.joined(separator: "\n")
    }

    // MARK: Private

    /// 「[HH:mm:ss] 本文」形式の行からタイムスタンプを取り出す（形式外は nil）
    private static func timestamp(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.prefixMatch(of: /\[(\d{2}:\d{2}:\d{2})\]\s/) else { return nil }
        return String(match.output.1)
    }
}
