import Foundation

// MARK: - TemplateExporter

/// 組み込みテンプレートを「# 表示名 + 指示本文」の md として書き出す。
/// 正本は BuiltInTemplates の Swift 定数で、スキル同梱 md はこの書き出しの成果物。
/// TemplateStore.parse との往復同一性はテストで保証する。
public enum TemplateExporter {
    @discardableResult public static func export(to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try BuiltInTemplates.all.map { template in
            let url = directory.appendingPathComponent("\(template.id).md")
            try "# \(template.displayName)\n\n\(template.instructions)\n"
                .write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }
}
