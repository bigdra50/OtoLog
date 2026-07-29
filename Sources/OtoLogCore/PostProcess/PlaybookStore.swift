import Foundation

// MARK: - PlaybookStore

/// ユーザー定義プレイブック（<XDG_CONFIG_HOME>/otolog/playbooks/<id>.json）を読み、組み込みとマージする。
/// 同 id はユーザー定義が組み込みを上書きする（位置は組み込みの位置を保つ）。
public struct PlaybookStore: Sendable {
    // MARK: Lifecycle

    public init(userPlaybooksDirectory: URL = PlaybookStore.defaultUserDirectory) {
        self.userPlaybooksDirectory = userPlaybooksDirectory
    }

    // MARK: Public

    /// XDG_CONFIG_HOME があればそれ、なければ ~/.config を基底にする（TemplateStore と同じ流儀）
    public static var defaultUserDirectory: URL {
        let environment = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let base = environment.flatMap { path in
            path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("otolog/playbooks", isDirectory: true)
    }

    /// JSON をパースし検証する。壊れた JSON・不正な依存グラフは nil（無効プレイブック）。
    /// id "auto" は設定の「内容から自動判定」の予約語なので使えない
    public static func parse(data: Data, id: String) -> Playbook? {
        guard id != "auto" else { return nil }
        guard let file = try? JSONDecoder().decode(PlaybookFile.self, from: data) else { return nil }
        let tasks = file.tasks.map { entry in
            PlaybookTask(
                templateID: entry.templateID,
                model: entry.model.flatMap(ClaudeModel.init(rawValue:)) ?? .sonnet,
                allowsWebResearch: entry.web ?? false,
                dependsOn: entry.dependsOn ?? []
            )
        }
        let playbook = Playbook(
            id: id,
            displayName: file.displayName ?? id,
            description: file.description ?? "",
            tasks: tasks
        )
        guard !tasks.isEmpty, playbook.validationError() == nil else { return nil }
        return playbook
    }

    /// 組み込み（定義順）にユーザー定義をマージして返す。追加分は id 昇順で末尾。
    /// UI から直接呼ぶため throw しない（ディレクトリ不在・壊れファイルはスキップ）
    public func loadPlaybooks() -> [Playbook] {
        var playbooks = BuiltInPlaybooks.all
        for user in loadUserPlaybooks() {
            if let index = playbooks.firstIndex(where: { $0.id == user.id }) {
                playbooks[index] = user
            } else {
                playbooks.append(user)
            }
        }
        return playbooks
    }

    // MARK: Private

    /// ユーザー定義 JSON のスキーマ。model 省略は sonnet、web 省略は false。
    /// description は内容ベースの自動判定の判定材料になる
    private struct PlaybookFile: Decodable {
        struct TaskEntry: Decodable {
            let templateID: String
            let model: String?
            let web: Bool?
            let dependsOn: [String]?
        }

        let displayName: String?
        let description: String?
        let tasks: [TaskEntry]
    }

    private let userPlaybooksDirectory: URL

    private func loadUserPlaybooks() -> [Playbook] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: userPlaybooksDirectory, includingPropertiesForKeys: nil
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return Self.parse(data: data, id: url.deletingPathExtension().lastPathComponent)
            }
    }
}
