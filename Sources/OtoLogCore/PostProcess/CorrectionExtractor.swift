import Foundation

// MARK: - CorrectionExtractor

/// 補正 diff から辞書化に適した置換ペアを抽出する。
/// 「equal に挟まれた removed → inserted」だけを語の修正とみなし、
/// 文脈依存の強い修正（純挿入・純削除、てにをは、長い書き換え）は捨てる。
public enum CorrectionExtractor {
    // MARK: Public

    public static func pairs(
        original: [TimestampedLogParser.Line],
        corrected: [TimestampedLogParser.Line]
    ) -> [CorrectionPair] {
        var pairs: [CorrectionPair] = []
        for entry in TranscriptDiff.changedEntries(original: original, corrected: corrected) {
            let segments = entry.segments
            // 行全体が追加/削除のみ（時刻不一致の行）は対象外
            guard segments.contains(where: { $0.kind == .equal }) else { continue }
            // 書き換え度が高い行は「文の言い換え」であり語の修正ではない。
            // LCS が偶然の共通文字を拾って無意味なペアを作るため、equal 率の低い行は捨てる
            let equalLength = segments.filter { $0.kind == .equal }.map(\.text.count).reduce(0, +)
            let newLength = segments.filter { $0.kind != .removed }.map(\.text.count).reduce(0, +)
            guard newLength > 0, Double(equalLength) / Double(newLength) >= 0.6 else { continue }
            var index = 0
            while index < segments.count {
                if segments[index].kind == .removed,
                   index + 1 < segments.count,
                   segments[index + 1].kind == .inserted {
                    let pair = CorrectionPair(text: segments[index].text, replacement: segments[index + 1].text)
                    if let pair {
                        pairs.append(pair)
                    }
                    index += 2
                } else {
                    index += 1
                }
            }
        }
        return pairs
    }

    // MARK: Private

    private static let maxPairLength = 12
}

private extension CorrectionPair {
    /// 辞書化に適さないペアは nil
    init?(text wrong: String, replacement right: String) {
        guard !wrong.isEmpty, !right.isEmpty,
              wrong.count <= 12, right.count <= 12,
              !(wrong.isHiraganaOnly && right.isHiraganaOnly)
        else { return nil }
        self.init(wrong: wrong, right: right)
    }
}

private extension String {
    var isHiraganaOnly: Bool {
        !isEmpty && unicodeScalars.allSatisfy { scalar in
            (0x3040...0x309F).contains(Int(scalar.value)) || scalar.properties.isWhitespace
        }
    }
}
