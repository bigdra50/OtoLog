import Foundation
import Observation

// MARK: - PostStopAction

/// 記録停止時に自動で行う後処理。
enum PostStopAction: String, CaseIterable {
    case none
    case title
    case titleAndPipeline

    // MARK: Internal

    var displayName: String {
        switch self {
        case .none: "なし"
        case .title: "タイトル生成"
        case .titleAndPipeline: "タイトル生成 + プレイブック"
        }
    }
}

// MARK: - AudioInputMode

/// 記録する音源の組み合わせ。
enum AudioInputMode: String, CaseIterable {
    case system
    case systemAndMicrophone
    case microphoneOnly

    // MARK: Internal

    var displayName: String {
        switch self {
        case .system: "システム音声のみ"
        case .systemAndMicrophone: "システム音声 + マイク"
        case .microphoneOnly: "マイクのみ"
        }
    }

    var usesMicrophone: Bool {
        self != .system
    }
}

// MARK: - UserDefaults + nonEmptyString

private extension UserDefaults {
    /// 入力欄を空にしたまま閉じると空文字列が保存される。string(forKey:) はそれを nil にせず返すため、
    /// `?? 既定値` を素通りして空のまま使われる（保存先が消える、claude が起動できない）。
    /// 空は未設定と同じ扱いにする
    func nonEmptyString(forKey key: String) -> String? {
        guard let value = string(forKey: key), !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - AppSettings

/// UserDefaults 永続化付きの設定。
@MainActor @Observable final class AppSettings {
    // MARK: Lifecycle

    /// defaults は差し替え可能。テストが実利用中の保存先を書き換えないようにするため
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        localeIdentifier = defaults.nonEmptyString(forKey: Self.localeKey) ?? "ja-JP"
        saveDirectoryPath = defaults.nonEmptyString(forKey: Self.directoryKey) ?? "~/Documents/OtoLog"
        claudeExecutablePath = defaults.nonEmptyString(forKey: Self.claudePathKey) ?? "~/.local/bin/claude"
        postStopAction = defaults.nonEmptyString(forKey: Self.postStopKey)
            .flatMap(PostStopAction.init(rawValue:)) ?? .none
        defaultPlaybookID = defaults.nonEmptyString(forKey: Self.defaultPlaybookKey) ?? Self.autoPlaybookID
        translationEnabled = defaults.bool(forKey: Self.translationEnabledKey)
        translationTargetIdentifier = defaults.nonEmptyString(forKey: Self.translationTargetKey)
            ?? Self.systemTranslationTarget
        // bool(forKey:) は未設定でも false になるため、既定 true は object の有無で判定する
        subtitleOverlayEnabled = defaults.object(forKey: Self.subtitleOverlayKey) as? Bool ?? true
        recognitionCandidates = defaults.stringArray(forKey: Self.recognitionCandidatesKey)
            ?? Self.defaultRecognitionCandidates
        audioInputMode = defaults.nonEmptyString(forKey: Self.audioInputModeKey)
            .flatMap(AudioInputMode.init(rawValue:)) ?? .system
        microphoneDeviceUID = defaults.nonEmptyString(forKey: Self.microphoneDeviceUIDKey)
    }

    // MARK: Internal

    /// 「内容から自動判定」を表す予約値（プレイブック id には使えない）
    static let autoPlaybookID = "auto"

    /// 「システム設定に従う」を表す予約値（BCP-47 と衝突しない）
    static let systemTranslationTarget = "system"

    /// 聞き取る言語を話者から判定させる予約値
    static let autoRecognitionLocale = "auto"

    /// 自動検出の既定候補。何語か分からない音源で当たりやすい順に並べる
    static let defaultRecognitionCandidates = ["en-US", "ja-JP"]

    var localeIdentifier: String {
        didSet { defaults.set(localeIdentifier, forKey: Self.localeKey) }
    }

    /// チルダ表記で保持し、表示にもそのまま使う
    var saveDirectoryPath: String {
        didSet { defaults.set(saveDirectoryPath, forKey: Self.directoryKey) }
    }

    /// チルダ表記で保持し、表示にもそのまま使う
    var claudeExecutablePath: String {
        didSet { defaults.set(claudeExecutablePath, forKey: Self.claudePathKey) }
    }

    var postStopAction: PostStopAction {
        didSet { defaults.set(postStopAction.rawValue, forKey: Self.postStopKey) }
    }

    /// 停止時の自動実行で使うプレイブック（autoPlaybookID なら内容から自動判定）
    var defaultPlaybookID: String {
        didSet { defaults.set(defaultPlaybookID, forKey: Self.defaultPlaybookKey) }
    }

    /// 記録中に確定セグメントを訳すか。既存の記録の挙動を変えないよう既定はオフ
    var translationEnabled: Bool {
        didSet { defaults.set(translationEnabled, forKey: Self.translationEnabledKey) }
    }

    /// systemTranslationTarget か BCP-47
    var translationTargetIdentifier: String {
        didSet { defaults.set(translationTargetIdentifier, forKey: Self.translationTargetKey) }
    }

    /// 記録中に訳を画面へ重ねる。翻訳が有効なときだけ効く
    var subtitleOverlayEnabled: Bool {
        didSet { defaults.set(subtitleOverlayEnabled, forKey: Self.subtitleOverlayKey) }
    }

    /// localeIdentifier が autoRecognitionLocale のときに並行認識する候補。
    /// 予約枠の都合で 5 個までしか渡せない（AssetInventory.maximumReservedLocales）
    var recognitionCandidates: [String] {
        didSet { defaults.set(recognitionCandidates, forKey: Self.recognitionCandidatesKey) }
    }

    /// 記録する音源の組み合わせ。次の記録開始から反映される
    var audioInputMode: AudioInputMode {
        didSet { defaults.set(audioInputMode.rawValue, forKey: Self.audioInputModeKey) }
    }

    /// 使用するマイクの UID。nil はシステム既定の入力デバイス
    var microphoneDeviceUID: String? {
        didSet { defaults.set(microphoneDeviceUID, forKey: Self.microphoneDeviceUIDKey) }
    }

    /// 実際に認識へ渡す候補。先頭は判定できなかったときの落としどころになる
    var resolvedRecognitionLocales: [String] {
        guard localeIdentifier == Self.autoRecognitionLocale else { return [localeIdentifier] }
        return recognitionCandidates.isEmpty ? Self.defaultRecognitionCandidates : recognitionCandidates
    }

    /// 実際に翻訳先として渡す BCP-47。
    /// システム既定は supportedLanguages に無い組み合わせ（en-Latn-JP 等）になり得るが、
    /// 正規化せず framework の解決に委ねる。言語コードで候補へ寄せ直すと
    /// 別地域（en-Latn-IN 等）を掴んで訳文が劣化する
    var resolvedTranslationTarget: String {
        translationTargetIdentifier == Self.systemTranslationTarget
            ? Locale.current.language.maximalIdentifier
            : translationTargetIdentifier
    }

    var saveDirectory: URL {
        URL(fileURLWithPath: (saveDirectoryPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    var claudeExecutableURL: URL {
        URL(fileURLWithPath: (claudeExecutablePath as NSString).expandingTildeInPath)
    }

    // MARK: Private

    private static let localeKey = "localeIdentifier"
    private static let directoryKey = "saveDirectoryPath"
    private static let claudePathKey = "claudeExecutablePath"
    private static let postStopKey = "postStopAction"
    private static let defaultPlaybookKey = "defaultPlaybookID"
    private static let translationEnabledKey = "translationEnabled"
    private static let translationTargetKey = "translationTargetIdentifier"
    private static let subtitleOverlayKey = "subtitleOverlayEnabled"
    private static let recognitionCandidatesKey = "recognitionCandidates"
    private static let audioInputModeKey = "audioInputMode"
    private static let microphoneDeviceUIDKey = "microphoneDeviceUID"

    private let defaults: UserDefaults
}
