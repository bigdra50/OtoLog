import Foundation
@testable import OtoLogCore
import Testing

struct PlaybookTests {
    // MARK: Internal

    @Test func builtInPlaybooksAreValidAndReferenceExistingTemplates() {
        #expect(BuiltInPlaybooks.all.map(\.id) == ["lecture", "meeting"])
        let templateIDs = Set(BuiltInTemplates.all.map(\.id))
        for playbook in BuiltInPlaybooks.all {
            #expect(playbook.validationError() == nil, "\(playbook.id) が不正")
            // description は内容ベースの自動判定（SessionClassifier）の判定材料になる
            #expect(!playbook.description.isEmpty, "\(playbook.id) に説明が無い")
            for task in playbook.tasks {
                #expect(templateIDs.contains(task.templateID), "\(task.templateID) のテンプレートが無い")
            }
        }
    }

    /// "auto" は設定の「内容から自動判定」の予約語なのでプレイブック id に使えない
    @Test func parseRejectsReservedAutoID() {
        let json = """
        {"tasks": [{"templateID": "digest", "model": "haiku"}]}
        """
        #expect(PlaybookStore.parse(data: Data(json.utf8), id: "auto") == nil)
    }

    /// 校正が先行し、統合タスク（share）が並列群の後になる依存構造の固定
    @Test func lecturePlaybookHasCorrectionFirstAndShareLast() {
        let lecture = BuiltInPlaybooks.all[0]
        let correct = lecture.tasks.first { $0.templateID == "correct" }
        let share = lecture.tasks.first { $0.templateID == "share" }
        #expect(correct?.dependsOn.isEmpty == true)
        #expect(share?.dependsOn.sorted() == ["glossary", "references", "summary"])
        // Web を使うのは調査系のみ
        let webTasks = lecture.tasks.filter(\.allowsWebResearch).map(\.templateID).sorted()
        #expect(webTasks == ["glossary", "references", "repro"])
    }

    @Test func validationDetectsDuplicateUnresolvedAndCyclicDependencies() {
        let duplicate = Playbook(id: "x", displayName: "x", tasks: [
            PlaybookTask(templateID: "a", model: .sonnet),
            PlaybookTask(templateID: "a", model: .haiku),
        ])
        #expect(duplicate.validationError() != nil)

        let unresolved = Playbook(id: "x", displayName: "x", tasks: [
            PlaybookTask(templateID: "a", model: .sonnet, dependsOn: ["missing"]),
        ])
        #expect(unresolved.validationError() != nil)

        let cyclic = Playbook(id: "x", displayName: "x", tasks: [
            PlaybookTask(templateID: "a", model: .sonnet, dependsOn: ["b"]),
            PlaybookTask(templateID: "b", model: .sonnet, dependsOn: ["a"]),
        ])
        #expect(cyclic.validationError() != nil)
    }

    @Test func parseReadsUserPlaybookJSON() {
        let json = """
        {
          "displayName": "ポッドキャスト",
          "tasks": [
            {"templateID": "correct", "model": "sonnet"},
            {"templateID": "digest", "model": "haiku", "web": true, "dependsOn": ["correct"]}
          ]
        }
        """
        let playbook = PlaybookStore.parse(data: Data(json.utf8), id: "podcast")
        #expect(playbook?.id == "podcast")
        #expect(playbook?.displayName == "ポッドキャスト")
        #expect(playbook?.tasks.count == 2)
        #expect(playbook?.tasks.last?.allowsWebResearch == true)
        #expect(playbook?.tasks.last?.dependsOn == ["correct"])
    }

    @Test func parseRejectsInvalidJSONAndInvalidDependencies() {
        #expect(PlaybookStore.parse(data: Data("{broken".utf8), id: "x") == nil)
        let cyclic = """
        {"tasks": [
            {"templateID": "a", "model": "sonnet", "dependsOn": ["b"]},
            {"templateID": "b", "model": "sonnet", "dependsOn": ["a"]}
        ]}
        """
        #expect(PlaybookStore.parse(data: Data(cyclic.utf8), id: "x") == nil)
    }

    @Test func userPlaybookOverridesBuiltInWithSameID() throws {
        try withTempDir { dir in
            let json = """
            {"displayName": "俺の講演", "tasks": [{"templateID": "summary", "model": "haiku"}]}
            """
            try json.write(to: dir.appendingPathComponent("lecture.json"), atomically: true, encoding: .utf8)

            let playbooks = PlaybookStore(userPlaybooksDirectory: dir).loadPlaybooks()

            let lecture = playbooks.filter { $0.id == "lecture" }
            #expect(lecture.count == 1)
            #expect(lecture.first?.displayName == "俺の講演")
            #expect(playbooks.map(\.id) == ["lecture", "meeting"])
        }
    }

    @Test func loadReturnsBuiltInsWhenDirectoryMissing() {
        let store = PlaybookStore(userPlaybooksDirectory: URL(fileURLWithPath: "/nonexistent/otolog-\(UUID())"))
        #expect(store.loadPlaybooks() == BuiltInPlaybooks.all)
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
