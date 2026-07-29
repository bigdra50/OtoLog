import Foundation
@testable import OtoLogCore
import Testing

struct TemplateExporterTests {
    // MARK: Internal

    /// export した md を TemplateStore.parse で読み戻すと元のテンプレートに一致する（往復同一性）。
    /// スキル同梱 md がアプリと同じテンプレート定義であることの根拠
    @Test func exportRoundTripsThroughParse() throws {
        try withTempDir { dir in
            let urls = try TemplateExporter.export(to: dir)
            #expect(urls.map(\.lastPathComponent).sorted()
                == BuiltInTemplates.all.map { "\($0.id).md" }.sorted())
            for template in BuiltInTemplates.all {
                let contents = try String(contentsOf: dir.appendingPathComponent("\(template.id).md"), encoding: .utf8)
                let parsed = TemplateStore.parse(fileContents: contents, id: template.id, isBuiltIn: true)
                #expect(parsed?.displayName == template.displayName)
                #expect(parsed?.instructions == template.instructions)
            }
        }
    }

    /// リポジトリにコミットされたスキル同梱 templates/ が Swift 定数（正本）からドリフトしていないことの検知。
    /// 落ちたら `swift run otolog-devtool export-templates skills/otolog-generate/templates` で再書き出しする
    @Test func committedSkillTemplatesMatchBuiltIns() throws {
        let repoRoot = URL(fileURLWithPath: #filePath) // Tests/OtoLogCoreTests/TemplateExporterTests.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let templatesDir = repoRoot.appendingPathComponent("skills/otolog-generate/templates", isDirectory: true)
        try withTempDir { expected in
            try TemplateExporter.export(to: expected)
            for template in BuiltInTemplates.all {
                let committed = try String(
                    contentsOf: templatesDir.appendingPathComponent("\(template.id).md"), encoding: .utf8
                )
                let exported = try String(
                    contentsOf: expected.appendingPathComponent("\(template.id).md"), encoding: .utf8
                )
                #expect(committed == exported, "skills/otolog-generate/templates/\(template.id).md が正本と不一致")
            }
        }
    }

    // MARK: Private

    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }
}
