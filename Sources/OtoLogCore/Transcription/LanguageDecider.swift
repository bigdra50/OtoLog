import Foundation
import NaturalLanguage

/// 複数ロケールで並行認識した結果から、実際に話されている言語を選ぶ。
///
/// 誤ったロケールの認識器は音を無理に写すため、日本語を英語で聞けばローマ字（"Hong jitsuba"）に、
/// 英語を日本語で聞けばカタカナ混じり（"Today Iant toトーク"）になる。
/// 出力を言語判定にかけると、正しい認識器だけが自分のロケールと一致する。
public enum LanguageDecider {
    // MARK: Public

    /// 判定に足る材料が無い、またはどの候補とも一致しないときは nil。
    /// 誤って絞るより待つほうが害が小さいので、確信が持てるまで決めない
    public static func decide(_ candidates: [(locale: String, text: String)]) -> String? {
        var best: (locale: String, confidence: Double)?
        for candidate in candidates {
            // 短い断片は言語判定が当てにならない。実測では誤ロケール側が 0.86 まで上がることがある
            guard candidate.text.count >= minimumCharacters else { continue }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(candidate.text)
            guard let dominant = recognizer.dominantLanguage,
                  matches(dominant, locale: candidate.locale),
                  let confidence = recognizer.languageHypotheses(withMaximum: 1)[dominant],
                  confidence >= minimumConfidence
            else { continue }
            if best == nil || confidence > best!.confidence {
                best = (candidate.locale, confidence)
            }
        }
        return best?.locale
    }

    // MARK: Private

    private static let minimumCharacters = 12
    private static let minimumConfidence = 0.9

    /// NLLanguage は中国語を表記体系込み（zh-Hans / zh-Hant）で返すが、
    /// ロケールの言語コードは zh。前方一致で見ないと中国語だけ永久に一致しない
    private static func matches(_ language: NLLanguage, locale: String) -> Bool {
        guard let code = Locale.Language(identifier: locale).languageCode?.identifier else { return false }
        let detected = language.rawValue
        return detected == code || detected.hasPrefix("\(code)-")
    }
}
