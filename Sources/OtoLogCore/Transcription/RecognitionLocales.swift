import Foundation
import Speech

/// 聞き取りに使えるロケールを Speech framework から引く。
public enum RecognitionLocales {
    // MARK: Public

    /// 自動検出で同時に走らせられる上限。予約枠はシステム全体で共有される
    public static var maximumCandidates: Int {
        AssetInventory.maximumReservedLocales
    }

    /// 音声認識が対応するロケール。モデル未 DL のものも含む（初回の記録開始時に落ちてくる）
    public static func supported(displayLocale: Locale = .current) async -> [LanguageChoice] {
        await make(from: SpeechTranscriber.supportedLocales, displayLocale: displayLocale)
    }

    /// モデルが DL 済みのロケール。自動検出の候補はここから選ばせる。
    /// 未 DL を混ぜると記録開始時に候補ぶんのダウンロードが走って待たされる
    public static func installed(displayLocale: Locale = .current) async -> [LanguageChoice] {
        await make(from: SpeechTranscriber.installedLocales, displayLocale: displayLocale)
    }

    // MARK: Private

    private static func make(from locales: [Locale], displayLocale: Locale) async -> [LanguageChoice] {
        LanguageChoiceList.make(
            identifiers: locales.map { $0.identifier(.bcp47) },
            displayLocale: displayLocale
        )
    }
}
