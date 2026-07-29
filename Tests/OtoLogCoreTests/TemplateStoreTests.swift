import Foundation
@testable import OtoLogCore
import Testing

struct TemplateStoreTests {
    // MARK: Internal

    @Test func parseExtractsDisplayNameFromFirstHeading() {
        let template = TemplateStore.parse(fileContents: "# 議事録\n\n決定事項を整理する", id: "minutes")
        #expect(template?.displayName == "議事録")
        #expect(template?.instructions == "決定事項を整理する")
        #expect(template?.isBuiltIn == false)
    }

    @Test func parseWithoutHeadingUsesIDAsDisplayName() {
        let template = TemplateStore.parse(fileContents: "指示だけのファイル", id: "custom")
        #expect(template?.displayName == "custom")
        #expect(template?.instructions == "指示だけのファイル")
    }

    /// 文中の見出しは表示名にしない。先頭（空行を除く）の見出しだけが表示名
    @Test func parseIgnoresHeadingAfterBody() {
        let template = TemplateStore.parse(fileContents: "前置き\n# 見出し", id: "custom")
        #expect(template?.displayName == "custom")
        #expect(template?.instructions == "前置き\n# 見出し")
    }

    @Test func parseEmptyInstructionsReturnsNil() {
        #expect(TemplateStore.parse(fileContents: "# 名前だけ\n\n   \n", id: "empty") == nil)
        #expect(TemplateStore.parse(fileContents: "", id: "empty") == nil)
    }

    @Test func loadReturnsBuiltInsWhenDirectoryMissing() {
        let store = TemplateStore(userTemplatesDirectory: URL(fileURLWithPath: "/nonexistent/otolog-\(UUID())"))
        #expect(store.loadTemplates() == BuiltInTemplates.all)
    }

    @Test func userTemplateOverridesBuiltInWithSameID() throws {
        try withTempDir { dir in
            try "# 上書き議事録\n\n独自指示".write(
                to: dir.appendingPathComponent("minutes.md"), atomically: true, encoding: .utf8
            )
            let templates = TemplateStore(userTemplatesDirectory: dir).loadTemplates()
            let minutes = templates.filter { $0.id == "minutes" }
            #expect(minutes.count == 1)
            #expect(minutes.first?.displayName == "上書き議事録")
            #expect(minutes.first?.isBuiltIn == false)
            // 上書きしても位置は組み込みの位置を保つ
            #expect(templates.map(\.id) == BuiltInTemplates.all.map(\.id))
        }
    }

    @Test func userTemplatesAppendAfterBuiltInsSortedByID() throws {
        try withTempDir { dir in
            try "# ブログ\n\n記事にする".write(
                to: dir.appendingPathComponent("blog.md"), atomically: true, encoding: .utf8
            )
            try "# 単語帳\n\n単語を抽出".write(
                to: dir.appendingPathComponent("vocab.md"), atomically: true, encoding: .utf8
            )
            let templates = TemplateStore(userTemplatesDirectory: dir).loadTemplates()
            let appended = templates.suffix(2).map(\.id)
            #expect(appended == ["blog", "vocab"])
        }
    }

    @Test func loadSkipsNonMarkdownAndInvalidFiles() throws {
        try withTempDir { dir in
            try "無視される".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
            try "# 空指示のみ\n".write(to: dir.appendingPathComponent("broken.md"), atomically: true, encoding: .utf8)
            let templates = TemplateStore(userTemplatesDirectory: dir).loadTemplates()
            #expect(templates == BuiltInTemplates.all)
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
