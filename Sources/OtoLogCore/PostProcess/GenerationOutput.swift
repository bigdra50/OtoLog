import Foundation

/// 生成結果を保存する形へ振り分ける。
///
/// 構造化出力を使うテンプレートでは JSON が機械用の正本で、
/// md はそこから組み立てた人が読む派生物になる（transcript.jsonl と transcript.md と同じ関係）。
public enum GenerationOutput {
    public static func files(templateID: String, generated: String) -> (markdown: String, json: String?) {
        // スキーマを指示しても JSON にならないことはある。
        // そのときは生成結果を捨てずに本文としてそのまま残す
        switch templateID {
        case "glossary":
            guard let document = try? GlossaryDocument(json: generated) else { return (generated, nil) }
            return (GlossaryFormatter.markdown(from: document), generated)
        case "actions":
            guard let document = try? ActionDocument(json: generated) else { return (generated, nil) }
            return (ActionFormatter.markdown(from: document), generated)
        default:
            return (generated, nil)
        }
    }
}
