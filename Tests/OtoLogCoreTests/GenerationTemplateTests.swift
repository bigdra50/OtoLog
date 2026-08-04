import Foundation
@testable import OtoLogCore
import Testing

struct GenerationTemplateTests {
    /// 組み込みの id は生成物ファイル名 <id>.md とスキル同梱 md の名前になる契約
    @Test func builtInsAreOrderedWithStableIDs() {
        #expect(BuiltInTemplates.all.map(\.id) == [
            "correct", "minutes", "lecture", "digest",
            "summary", "glossary", "references", "qa", "repro", "share", "actions", "followup",
            "situation",
        ])
    }

    @Test func builtInIDsAreUnique() {
        let ids = BuiltInTemplates.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func builtInsHaveDisplayNameAndInstructions() {
        for template in BuiltInTemplates.all {
            #expect(!template.displayName.isEmpty)
            #expect(!template.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(template.isBuiltIn)
        }
    }

    /// id はファイル名とシェルに安全な文字だけで構成する（英小文字・数字・ハイフン）
    @Test func builtInIDsAreFilenameSafe() {
        for template in BuiltInTemplates.all {
            #expect(template.id.wholeMatch(of: /[a-z0-9-]+/) != nil)
        }
    }
}
