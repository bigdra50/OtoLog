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

// MARK: - AppSettings

/// UserDefaults 永続化付きの設定。
@MainActor @Observable final class AppSettings {
    // MARK: Lifecycle

    init() {
        let defaults = UserDefaults.standard
        localeIdentifier = defaults.string(forKey: Self.localeKey) ?? "ja-JP"
        saveDirectoryPath = defaults.string(forKey: Self.directoryKey) ?? "~/Documents/OtoLog"
        claudeExecutablePath = defaults.string(forKey: Self.claudePathKey) ?? "~/.local/bin/claude"
        postStopAction = defaults.string(forKey: Self.postStopKey)
            .flatMap(PostStopAction.init(rawValue:)) ?? .none
        defaultPlaybookID = defaults.string(forKey: Self.defaultPlaybookKey) ?? Self.autoPlaybookID
    }

    // MARK: Internal

    /// 「内容から自動判定」を表す予約値（プレイブック id には使えない）
    static let autoPlaybookID = "auto"

    var localeIdentifier: String {
        didSet { UserDefaults.standard.set(localeIdentifier, forKey: Self.localeKey) }
    }

    /// チルダ表記で保持し、表示にもそのまま使う
    var saveDirectoryPath: String {
        didSet { UserDefaults.standard.set(saveDirectoryPath, forKey: Self.directoryKey) }
    }

    /// チルダ表記で保持し、表示にもそのまま使う
    var claudeExecutablePath: String {
        didSet { UserDefaults.standard.set(claudeExecutablePath, forKey: Self.claudePathKey) }
    }

    var postStopAction: PostStopAction {
        didSet { UserDefaults.standard.set(postStopAction.rawValue, forKey: Self.postStopKey) }
    }

    /// 停止時の自動実行で使うプレイブック（autoPlaybookID なら内容から自動判定）
    var defaultPlaybookID: String {
        didSet { UserDefaults.standard.set(defaultPlaybookID, forKey: Self.defaultPlaybookKey) }
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
}
