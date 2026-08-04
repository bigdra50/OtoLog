import Foundation
@testable import OtoLogCore
import Testing

struct PromptBuilderTests {
    let jst = TimeZone(identifier: "Asia/Tokyo")!
    let template = GenerationTemplate(id: "minutes", displayName: "議事録", instructions: "決定事項を整理する", isBuiltIn: true)
    let session = SessionRef(
        directoryName: "2026-07-29_1300_CEDEC講演",
        title: "CEDEC講演",
        startedAt: Date(timeIntervalSince1970: 1_785_297_600)
    )

    @Test func includesSystemRulesTemplateInstructionsAndSessionInfo() {
        let prompt = PromptBuilder(timeZone: jst).prompt(
            template: template, session: session,
            segments: [TestFixtures.segment(text: "こんにちは")]
        )
        #expect(prompt.contains("結果の Markdown 本文のみ"))
        #expect(prompt.contains("決定事項を整理する"))
        #expect(prompt.contains("CEDEC講演（2026-07-29 13:00 開始）"))
    }

    /// finalizedAt 1785297600 = 2026-07-29 13:00:00 JST。ログ行はローカル時刻で刻む
    @Test func formatsSegmentsAsTimestampedLinesInTimeZone() {
        let prompt = PromptBuilder(timeZone: jst).prompt(
            template: template, session: session,
            segments: [
                TestFixtures.segment(text: "最初の発話"),
                TestFixtures.segment(text: "次の発話", finalizedAt: Date(timeIntervalSince1970: 1_785_297_612)),
            ]
        )
        #expect(prompt.contains("[13:00:00] 最初の発話\n[13:00:12] 次の発話"))
    }

    /// 育てた修正辞書はプロンプトの専用セクションとして注入される
    @Test func injectsCorrectionDictionarySection() {
        let corrections = [
            CorrectionEntry(
                wrong: "家紋", right: "山", count: 3,
                firstSeenAt: Date(timeIntervalSince1970: 1_785_297_600),
                lastSeenAt: Date(timeIntervalSince1970: 1_785_297_600)
            ),
        ]
        let prompt = PromptBuilder(timeZone: jst).prompt(
            template: template, session: session,
            segments: [TestFixtures.segment(text: "本文")],
            corrections: corrections
        )
        #expect(prompt.contains("既知の修正辞書"))
        #expect(prompt.contains("- 家紋 → 山"))
        // 辞書なしならセクション自体が出ない
        let plain = PromptBuilder(timeZone: jst).prompt(
            template: template, session: session, segments: [TestFixtures.segment(text: "本文")]
        )
        #expect(!plain.contains("既知の修正辞書"))
    }

    @Test func collapsesNewlinesInsideSegmentText() {
        let prompt = PromptBuilder(timeZone: jst).prompt(
            template: template, session: session,
            segments: [TestFixtures.segment(text: "1行目\n2行目")]
        )
        #expect(prompt.contains("[13:00:00] 1行目 2行目"))
    }

    /// 前提知識は用語と説明の対で渡す。
    /// 語だけでは何者か分からず、音が近いだけの箇所まで引き寄せてしまう
    @Test func injectsKnowledgeWithDescriptions() {
        let prompt = PromptBuilder(timeZone: jst).prompt(
            template: template, session: session, logBody: "本文",
            knowledge: [KnowledgeEntry(term: "XREAL AURA", body: "XREAL 社の AR グラス。")]
        )

        #expect(prompt.contains("XREAL AURA"))
        #expect(prompt.contains("XREAL 社の AR グラス。"))
    }

    @Test func omitsKnowledgeSectionWhenEmpty() {
        let prompt = PromptBuilder(timeZone: jst).prompt(
            template: template, session: session, logBody: "本文", knowledge: []
        )

        #expect(!prompt.contains("前提知識"))
    }

    /// ツールが使えなかった等の実行上の問題を、生成物本文の謝罪・権限要求で報告させない。
    /// 「WebSearchの使用を許可していただけますでしょうか」が成果物として保存された実例への対策
    @Test func forbidsApologyForRuntimeProblemsInOutput() {
        let prompt = PromptBuilder(timeZone: jst).prompt(
            template: template, session: session, logBody: "本文"
        )

        #expect(prompt.contains("謝罪や許可の要求をしない"))
    }
}
