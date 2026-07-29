import CoreMedia
import Foundation
@testable import OtoLogCore
import Speech
import Testing

struct TranscriberEventMapperTests {
    // MARK: Internal

    let context = TranscriptionContext(
        locale: "ja-JP",
        source: .system,
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        sessionStartedAt: Date(timeIntervalSince1970: 1_785_297_540)
    )
    let now = Date(timeIntervalSince1970: 1_785_297_600.500)

    @Test func mapsNonFinalToVolatile() {
        let event = TranscriberEventMapper.map(
            text: AttributedString("聞き取り中"), isFinal: false, context: context, now: now
        )
        #expect(event == .volatile("聞き取り中"))
    }

    @Test func mapsFinalWithTimeRangeToFinalizedSegment() {
        let text = attributedText(
            "こんにちは",
            timeRange: CMTimeRange(
                start: CMTime(seconds: 1.5, preferredTimescale: 600),
                duration: CMTime(seconds: 1.75, preferredTimescale: 600)
            )
        )
        let event = TranscriberEventMapper.map(text: text, isFinal: true, context: context, now: now)

        guard case let .finalized(segment) = event else {
            Issue.record("finalized ではなかった: \(String(describing: event))")
            return
        }
        #expect(segment.text == "こんにちは")
        #expect(segment.audioStart == 1.5)
        #expect(segment.audioEnd == 3.25)
        #expect(segment.finalizedAt == now)
        #expect(segment.locale == "ja-JP")
        #expect(segment.source == .system)
        #expect(segment.sessionID == context.sessionID)
        #expect(segment.sessionStartedAt == context.sessionStartedAt)
    }

    @Test func mapsFinalWithoutTimeRangeToNilAudioTimes() {
        let event = TranscriberEventMapper.map(
            text: AttributedString("属性なし"), isFinal: true, context: context, now: now
        )
        guard case let .finalized(segment) = event else {
            Issue.record("finalized ではなかった: \(String(describing: event))")
            return
        }
        #expect(segment.audioStart == nil)
        #expect(segment.audioEnd == nil)
    }

    @Test func returnsNilForWhitespaceOnlyText() {
        let volatileEvent = TranscriberEventMapper.map(
            text: AttributedString(" \n\t "), isFinal: false, context: context, now: now
        )
        #expect(volatileEvent == nil)
        let finalEvent = TranscriberEventMapper.map(
            text: AttributedString(" \n\t "), isFinal: true, context: context, now: now
        )
        #expect(finalEvent == nil)
    }

    // MARK: Private

    private func attributedText(_ string: String, timeRange: CMTimeRange) -> AttributedString {
        var container = AttributeContainer()
        container[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = timeRange
        return AttributedString(string, attributes: container)
    }
}
