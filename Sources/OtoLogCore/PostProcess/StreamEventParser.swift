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

    /// 収集したツール実行の問題（発生順・同一ツール同種は1件）。
    /// 権限拒否された呼び出しは is_error の tool_result としても流れてくるため、
    /// 権限拒否があるツールの実行失敗は重ねて数えない
    func collectedToolIssues() -> [ToolIssue] {
        lock.withLock {
            let deniedTools = Set(issues.filter { $0.kind == .permissionDenied }.map(\.toolName))
            var seen = Set<String>()
            return issues
                .filter { $0.kind == .permissionDenied || !deniedTools.contains($0.toolName) }
                .filter { seen.insert("\($0.toolName)/\($0.kind.rawValue)").inserted }
        }
    }

    // MARK: Private

    private let onPartial: @Sendable (String) -> Void
    private let lock = NSLock()
    private let newline = Data("\n".utf8)
    private var buffer = Data()
    private var accumulatedText = ""
    private var resultText: String?
    private var issues: [ToolIssue] = []
    /// tool_result（tool_use_id しか持たない）からツール名を引くための対応表
    private var toolNamesByUseID: [String: String] = [:]

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
        case "assistant":
            for block in contentBlocks(of: object) where block["type"] as? String == "tool_use" {
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                toolNamesByUseID[id] = name
            }
        case "user":
            for block in contentBlocks(of: object) where block["type"] as? String == "tool_result" {
                guard block["is_error"] as? Bool == true else { continue }
                let name = (block["tool_use_id"] as? String).flatMap { toolNamesByUseID[$0] } ?? "ツール"
                issues.append(ToolIssue(toolName: name, kind: .executionFailed))
            }
        case "result":
            resultText = object["result"] as? String
            for denial in object["permission_denials"] as? [[String: Any]] ?? [] {
                guard let name = denial["tool_name"] as? String else { continue }
                issues.append(ToolIssue(toolName: name, kind: .permissionDenied))
            }
        default:
            break
        }
    }

    private func contentBlocks(of object: [String: Any]) -> [[String: Any]] {
        guard let message = object["message"] as? [String: Any] else { return [] }
        return message["content"] as? [[String: Any]] ?? []
    }
}
