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

extension CorrectionPair {
    /// 辞書化に適さないペアは nil。
    ///
    /// 置換元が1文字のものを落とすのが要点。実辞書では「ご→誤」「ラ→ナ」「デ→レ」が
    /// 最頻出になっていて、文脈を選ばず当たるうえに有用なエントリを頻度順で押しのけていた。
    /// 置換先は1文字でもよい（「家紋→山」のような固有名詞の補正が該当する）
    init?(text wrong: String, replacement right: String) {
        // 既存辞書の濾過（CorrectionDictionaryStore.load）からも同じ基準で呼ばれる
        let wrong = wrong.trimmingCharacters(in: .whitespaces)
        let right = right.trimmingCharacters(in: .whitespaces)
        guard wrong.count >= 2, !right.isEmpty,
              wrong.count <= 12, right.count <= 12,
              !(wrong.isHiraganaOnly && right.isHiraganaOnly),
              wrong.hasLetterOrDigit, right.hasLetterOrDigit
        else { return nil }
        self.init(wrong: wrong, right: right)
    }
}

private extension String {
    /// 記号・空白だけの差分（句読点の揺れ）は語の修正ではないので辞書化しない
    var hasLetterOrDigit: Bool {
        unicodeScalars.contains { $0.properties.isAlphabetic || ("0"..."9").contains(Character($0)) }
    }

    var isHiraganaOnly: Bool {
        !isEmpty && unicodeScalars.allSatisfy { scalar in
            (0x3040...0x309F).contains(Int(scalar.value)) || scalar.properties.isWhitespace
        }
    }
}
