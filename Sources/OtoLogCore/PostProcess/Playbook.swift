import Foundation

// MARK: - PlaybookTask

/// プレイブック内の1タスク。テンプレート（生成指示）と実行属性（モデル・Web 可否・依存）の束。
/// id はテンプレート id と同一で、出力ファイル名 <id>.md になる。
public struct PlaybookTask: Sendable, Equatable, Identifiable {
    // MARK: Lifecycle

    public init(
        templateID: String,
        model: ClaudeModel,
        allowsWebResearch: Bool = false,
        dependsOn: [String] = []
    ) {
        self.templateID = templateID
        self.model = model
        self.allowsWebResearch = allowsWebResearch
        self.dependsOn = dependsOn
    }

    // MARK: Public

    public let templateID: String
    public let model: ClaudeModel
    public let allowsWebResearch: Bool
    public let dependsOn: [String]

    public var id: String {
        templateID
    }
}

// MARK: - Playbook

/// 記録セッションへ適用するタスクの組合せ（依存グラフ）。
public struct Playbook: Sendable, Equatable, Identifiable {
    // MARK: Lifecycle

    public init(id: String, displayName: String, description: String = "", tasks: [PlaybookTask]) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.tasks = tasks
    }

    // MARK: Public

    public let id: String
    public let displayName: String
    /// どんな記録に適用すべきかの説明。内容ベースの自動判定（SessionClassifier）の判定材料
    public let description: String
    public let tasks: [PlaybookTask]

    /// nil なら妥当。タスク重複・未解決依存・循環を検出する
    public func validationError() -> String? {
        let ids = tasks.map(\.templateID)
        guard Set(ids).count == ids.count else {
            return "タスク id が重複しています"
        }
        let idSet = Set(ids)
        for task in tasks {
            for dependency in task.dependsOn where !idSet.contains(dependency) {
                return "\(task.templateID) の依存先 \(dependency) がありません"
            }
        }
        // Kahn 法: 全タスクをトポロジカル順に処理できなければ循環がある
        var remainingDependencies = Dictionary(uniqueKeysWithValues: tasks.map { ($0.templateID, Set($0.dependsOn)) })
        var resolved = 0
        while resolved < tasks.count {
            let ready = remainingDependencies.filter(\.value.isEmpty).map(\.key)
            guard !ready.isEmpty else {
                return "依存関係に循環があります"
            }
            for id in ready {
                remainingDependencies.removeValue(forKey: id)
                resolved += 1
            }
            for (id, dependencies) in remainingDependencies {
                remainingDependencies[id] = dependencies.subtracting(ready)
            }
        }
        return nil
    }
}

// MARK: - BuiltInPlaybooks

/// 組み込みプレイブック。校正を先行させ、変換系・調査系を並列、統合系を最後に置く共通構造。
public enum BuiltInPlaybooks {
    // MARK: Public

    public static let all: [Playbook] = [lecture, meeting]

    // MARK: Internal

    static let lecture = Playbook(
        id: "lecture",
        displayName: "講演",
        description: "カンファレンス発表・セミナー・勉強会・チュートリアルなど、発表者が聴衆へ一方向に説明する記録",
        tasks: [
            PlaybookTask(templateID: "correct", model: .sonnet),
            PlaybookTask(templateID: "summary", model: .sonnet, dependsOn: ["correct"]),
            PlaybookTask(templateID: "glossary", model: .sonnet, allowsWebResearch: true, dependsOn: ["correct"]),
            PlaybookTask(templateID: "references", model: .sonnet, allowsWebResearch: true, dependsOn: ["correct"]),
            PlaybookTask(templateID: "qa", model: .haiku, dependsOn: ["correct"]),
            PlaybookTask(templateID: "repro", model: .opus, allowsWebResearch: true, dependsOn: ["correct"]),
            PlaybookTask(templateID: "share", model: .sonnet, dependsOn: ["summary", "glossary", "references"]),
        ]
    )

    static let meeting = Playbook(
        id: "meeting",
        displayName: "会議",
        description: "複数の参加者が議論・意思決定・進捗確認を行う会議やミーティングの記録",
        tasks: [
            PlaybookTask(templateID: "correct", model: .sonnet),
            PlaybookTask(templateID: "minutes", model: .sonnet, dependsOn: ["correct"]),
            PlaybookTask(templateID: "actions", model: .sonnet, dependsOn: ["correct"]),
            PlaybookTask(templateID: "followup", model: .sonnet, dependsOn: ["minutes"]),
        ]
    )
}
