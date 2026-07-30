import Foundation

// MARK: - LanguageChoice

/// 翻訳先の選択肢1件。
public struct LanguageChoice: Sendable, Equatable, Identifiable {
    // MARK: Lifecycle

    public init(identifier: String, displayName: String) {
        self.identifier = identifier
        self.displayName = displayName
    }

    // MARK: Public

    /// 翻訳先として framework へ渡す BCP-47。表示の都合で畳んでもこちらは加工しない
    public let identifier: String
    public let displayName: String

    public var id: String {
        identifier
    }
}

// MARK: - LanguageChoiceList

/// 翻訳先の識別子から、選択肢として読める表示名を作る。
public enum LanguageChoiceList {
    /// 同じ言語に複数あるときだけ表記体系・地域を表示へ残す。
    /// maximalIdentifier をそのまま訳すと「英語（ラテン文字、アメリカ合衆国）」のように冗長になり、
    /// かといって言語コードだけにすると簡体・繁体の区別が消える
    public static func make(identifiers: [String], displayLocale: Locale) -> [LanguageChoice] {
        let languages = identifiers.map { ($0, Locale.Language(identifier: $0)) }
        var scripts: [String: Set<String>] = [:]
        var regions: [String: Set<String>] = [:]
        for (_, language) in languages {
            guard let code = language.languageCode?.identifier else { continue }
            if let script = language.script?.identifier { scripts[code, default: []].insert(script) }
            if let region = language.region?.identifier { regions[code, default: []].insert(region) }
        }

        return languages
            .compactMap { identifier, language -> LanguageChoice? in
                guard let code = language.languageCode?.identifier else { return nil }
                var components = [code]
                if scripts[code, default: []].count > 1, let script = language.script?.identifier {
                    components.append(script)
                }
                if regions[code, default: []].count > 1, let region = language.region?.identifier {
                    components.append(region)
                }
                let displayIdentifier = components.joined(separator: "-")
                return LanguageChoice(
                    identifier: identifier,
                    displayName: displayLocale.localizedString(forIdentifier: displayIdentifier) ?? identifier
                )
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}
