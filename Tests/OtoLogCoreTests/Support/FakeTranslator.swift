import Foundation
@testable import OtoLogCore

/// Translator のテストダブル。結果と遅延を差し替えられる。
final class FakeTranslator: Translator, @unchecked Sendable {
    // MARK: Internal

    var result: Result<TranslatedText, any Error> = .success(
        TranslatedText(text: "translated", locale: "en-US")
    )

    /// タイムアウト検証用。translate をこの時間だけ待たせる
    var delay: Duration?

    var receivedTexts: [String] {
        lock.withLock { _receivedTexts }
    }

    func translate(_ text: String) async throws -> TranslatedText {
        lock.withLock { _receivedTexts.append(text) }
        // 打ち切られた後に翻訳が完了しても記録へ影響しないことを示すため、キャンセルは握る
        if let delay { try? await Task.sleep(for: delay) }
        return try result.get()
    }

    // MARK: Private

    private let lock = NSLock()
    private var _receivedTexts: [String] = []
}
