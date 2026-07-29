import Foundation

/// 文字起こし原文と補正ログを時刻で突合し、変更があった行だけを抽出する。
/// 補正の確認導線（違和感のある箇所だけ原文と見比べる）のためのビュー用データ。
public enum TranscriptDiff {
    public struct Entry: Sendable, Equatable {
        // MARK: Lifecycle

        public init(time: String, segments: [CharacterDiff.Segment]) {
            self.time = time
            self.segments = segments
        }

        // MARK: Public

        public let time: String
        public let segments: [CharacterDiff.Segment]
    }

    public static func changedEntries(
        original: [TimestampedLogParser.Line],
        corrected: [TimestampedLogParser.Line]
    ) -> [Entry] {
        // 同時刻の複数行に備え、時刻ごとのキューとして持ち出現順に消費する
        var originalQueues: [String: [String]] = [:]
        for line in original {
            originalQueues[line.time, default: []].append(line.text)
        }

        var entries: [Entry] = []
        for line in corrected {
            if var queue = originalQueues[line.time], !queue.isEmpty {
                let originalText = queue.removeFirst()
                originalQueues[line.time] = queue
                guard originalText != line.text else { continue }
                entries.append(Entry(time: line.time, segments: CharacterDiff.diff(old: originalText, new: line.text)))
            } else {
                entries.append(Entry(
                    time: line.time,
                    segments: [CharacterDiff.Segment(text: line.text, kind: .inserted)]
                ))
            }
        }

        // 補正側で消費されなかった原文行は「補正で失われた行」として出す
        for (time, queue) in originalQueues {
            for text in queue {
                entries.append(Entry(time: time, segments: [CharacterDiff.Segment(text: text, kind: .removed)]))
            }
        }

        return entries.sorted { $0.time < $1.time }
    }
}
