import Foundation

/// claude -p --output-format stream-json の JSONL を逐次パースする。
/// content_block_delta の本文・thinking を onPartial へ流し、最終テキストは result イベントから取る。
/// チャンクは行境界と無関係に届くため、行バッファリングを内部で行う（NSLock で直列化）。
final class StreamEventParser: @unchecked Sendable {
    // MARK: Lifecycle

    init(onPartial: @escaping @Sendable (String) -> Void) {
        self.onPartial = onPartial
    }

    // MARK: Internal

    func consume(_ chunk: Data) {
        lock.withLock {
            buffer.append(chunk)
            while let range = buffer.range(of: newline) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                parse(line: lineData)
            }
        }
    }

    /// result イベントの最終テキスト。イベントが無ければ text デルタの結合、それも無ければ生 stdout
    func finalResult(fallbackStdout: Data) -> String {
        lock.withLock {
            if !buffer.isEmpty {
                parse(line: buffer)
                buffer.removeAll()
            }
            if let resultText { return resultText }
            if !accumulatedText.isEmpty { return accumulatedText }
            return String(decoding: fallbackStdout, as: UTF8.self)
        }
    }

    // MARK: Private

    private let onPartial: @Sendable (String) -> Void
    private let lock = NSLock()
    private let newline = Data("\n".utf8)
    private var buffer = Data()
    private var accumulatedText = ""
    private var resultText: String?

    private func parse(line: Data) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String
        else { return }

        switch type {
        case "stream_event":
            guard let event = object["event"] as? [String: Any],
                  let delta = event["delta"] as? [String: Any] else { return }
            if let text = delta["text"] as? String {
                accumulatedText += text
                onPartial(text)
            } else if let thinking = delta["thinking"] as? String {
                // thinking は最終テキストには含めず、進捗表示にだけ流す
                onPartial(thinking)
            }
        case "result":
            resultText = object["result"] as? String
        default:
            break
        }
    }
}
