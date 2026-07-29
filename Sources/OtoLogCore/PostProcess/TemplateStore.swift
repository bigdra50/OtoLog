import Foundation

// MARK: - TemplateStore

/// ユーザー定義テンプレート（<XDG_CONFIG_HOME>/otolog/templates/<id>.md）を読み、組み込みとマージする。
/// 同 id はユーザー定義が組み込みを上書きする（位置は組み込みの位置を保つ）。
public struct TemplateStore: Sendable {
    // MARK: Lifecycle

    public init(userTemplatesDirectory: URL = TemplateStore.defaultUserDirectory) {
        self.userTemplatesDirectory = userTemplatesDirectory
    }

    // MARK: Public

    /// XDG_CONFIG_HOME があればそれ、なければ ~/.config を基底にする
    public static var defaultUserDirectory: URL {
        let environment = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let base = environment.flatMap { path in
            path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("otolog/templates", isDirectory: true)
    }

    /// 最初の非空行が「# 見出し」なら表示名、それ以降全部を指示とする。
    /// 見出しが無ければ表示名は id。指示が空なら nil（無効テンプレート）
    public static func parse(fileContents: String, id: String, isBuiltIn: Bool = false) -> GenerationTemplate? {
        var lines = fileContents.split(separator: "\n", omittingEmptySubsequences: false)[...]
        var displayName = id
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines = lines.dropFirst()
        }
        if let first = lines.first, first.hasPrefix("# ") {
            displayName = first.dropFirst(2).trimmingCharacters(in: .whitespaces)
            lines = lines.dropFirst()
        }
        let instructions = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty else { return nil }
        return GenerationTemplate(id: id, displayName: displayName, instructions: instructions, isBuiltIn: isBuiltIn)
    }

    /// 組み込み（定義順）にユーザー定義をマージして返す。追加分は id 昇順で末尾。
    /// UI から直接呼ぶため throw しない（ディレクトリ不在・壊れファイルはスキップ）
    public func loadTemplates() -> [GenerationTemplate] {
        var templates = BuiltInTemplates.all
        for user in loadUserTemplates() {
            if let index = templates.firstIndex(where: { $0.id == user.id }) {
                templates[index] = user
            } else {
                templates.append(user)
            }
        }
        return templates
    }

    // MARK: Private

    private let userTemplatesDirectory: URL

    private func loadUserTemplates() -> [GenerationTemplate] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: userTemplatesDirectory, includingPropertiesForKeys: nil
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return Self.parse(fileContents: contents, id: url.deletingPathExtension().lastPathComponent)
            }
    }
}
