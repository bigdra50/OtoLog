import Foundation

/// 文字単位の diff（LCS ベース）。補正ログと原文の行内差分表示に使う。
public enum CharacterDiff {
    // MARK: Public

    public enum Kind: Sendable, Equatable {
        case equal
        case removed
        case inserted
    }

    public struct Segment: Sendable, Equatable {
        // MARK: Lifecycle

        public init(text: String, kind: Kind) {
            self.text = text
            self.kind = kind
        }

        // MARK: Public

        public let text: String
        public let kind: Kind
    }

    public static func diff(old: String, new: String) -> [Segment] {
        let oldCharacters = Array(old)
        let newCharacters = Array(new)

        // 表計算の爆発を避ける。1行の発話でこの長さは異常系なので全置換で十分
        guard oldCharacters.count <= maxLCSLength, newCharacters.count <= maxLCSLength else {
            var segments: [Segment] = []
            if !old.isEmpty { segments.append(Segment(text: old, kind: .removed)) }
            if !new.isEmpty { segments.append(Segment(text: new, kind: .inserted)) }
            return segments
        }

        // LCS 長の DP 表を組み、後ろから辿って編集列を作る
        let rows = oldCharacters.count
        let columns = newCharacters.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: columns + 1), count: rows + 1)
        if rows > 0, columns > 0 {
            for row in 1...rows {
                for column in 1...columns {
                    table[row][column] = oldCharacters[row - 1] == newCharacters[column - 1]
                        ? table[row - 1][column - 1] + 1
                        : max(table[row - 1][column], table[row][column - 1])
                }
            }
        }

        var reversed: [(character: Character, kind: Kind)] = []
        var row = rows
        var column = columns
        while row > 0 || column > 0 {
            if row > 0, column > 0, oldCharacters[row - 1] == newCharacters[column - 1] {
                reversed.append((oldCharacters[row - 1], .equal))
                row -= 1
                column -= 1
            } else if column > 0, row == 0 || table[row][column - 1] >= table[row - 1][column] {
                reversed.append((newCharacters[column - 1], .inserted))
                column -= 1
            } else {
                reversed.append((oldCharacters[row - 1], .removed))
                row -= 1
            }
        }

        // 同種の連続文字を1セグメントへ畳む。表示順は removed → inserted が読みやすいが、
        // ここは走査順のまま返し、順序は LCS の辿りに委ねる
        var segments: [Segment] = []
        for (character, kind) in reversed.reversed() {
            if let last = segments.last, last.kind == kind {
                segments[segments.count - 1] = Segment(text: last.text + String(character), kind: kind)
            } else {
                segments.append(Segment(text: String(character), kind: kind))
            }
        }
        return segments
    }

    // MARK: Private

    private static let maxLCSLength = 1000
}
