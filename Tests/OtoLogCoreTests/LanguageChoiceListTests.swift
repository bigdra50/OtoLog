import Foundation
@testable import OtoLogCore
import Testing

struct LanguageChoiceListTests {
    let ja = Locale(identifier: "ja-JP")

    /// 表記体系が1つしかない言語では script を表示から落とす。
    /// maximalIdentifier をそのまま訳すと「英語（ラテン文字、アメリカ合衆国）」になり冗長
    @Test func omitsScriptWhenLanguageHasSingleScript() {
        let targets = LanguageChoiceList.make(
            identifiers: ["en-Latn-US", "en-Latn-GB"], displayLocale: ja
        )

        #expect(Set(targets.map(\.displayName)) == ["英語（アメリカ合衆国）", "英語（イギリス）"])
    }

    /// 簡体・繁体のように表記体系が割れる言語では script を残す
    @Test func keepsScriptWhenLanguageHasMultipleScripts() {
        let targets = LanguageChoiceList.make(
            identifiers: ["zh-Hans-CN", "zh-Hant-TW", "zh-Hant-HK"], displayLocale: ja
        )

        #expect(Set(targets.map(\.displayName)) == [
            "簡体中国語（中国本土）", "繁体中国語（台湾）", "繁体中国語（香港）",
        ])
    }

    /// 地域が1つしかない言語では地域も落とす
    @Test func omitsRegionWhenLanguageHasSingleRegion() {
        let targets = LanguageChoiceList.make(
            identifiers: ["ko-Kore-KR", "da-Latn-DK"], displayLocale: ja
        )

        #expect(Set(targets.map(\.displayName)) == ["韓国語", "デンマーク語"])
    }

    /// 表示をどう畳んでも、翻訳先として渡す識別子は元のまま
    @Test func keepsOriginalIdentifier() {
        let targets = LanguageChoiceList.make(
            identifiers: ["en-Latn-US", "zh-Hans-CN"], displayLocale: ja
        )

        #expect(Set(targets.map(\.identifier)) == ["en-Latn-US", "zh-Hans-CN"])
    }

    /// 実際の候補群に近い混在リストでも、言語ごとに畳み方が切り替わる
    @Test func foldsPerLanguageInMixedList() {
        let targets = LanguageChoiceList.make(
            identifiers: ["en-Latn-US", "en-Latn-GB", "ko-Kore-KR", "zh-Hans-CN", "zh-Hant-TW", "pt-Latn-BR", "pt-Latn-PT"],
            displayLocale: ja
        )

        #expect(Set(targets.map(\.displayName)) == [
            "英語（アメリカ合衆国）", "英語（イギリス）", "韓国語",
            "簡体中国語（中国本土）", "繁体中国語（台湾）",
            "ポルトガル語（ブラジル）", "ポルトガル語（ポルトガル）",
        ])
    }

    @Test func returnsEmptyForEmptyInput() {
        #expect(LanguageChoiceList.make(identifiers: [], displayLocale: ja).isEmpty)
    }
}
