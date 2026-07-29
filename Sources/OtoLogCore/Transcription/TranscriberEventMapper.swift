import CoreMedia
import Foundation
import Speech

// MARK: - TranscriberEventMapper

/// SpeechTranscriber の結果（AttributedString + isFinal）を TranscriptEvent へ写す純粋関数。
public enum TranscriberEventMapper {
    public static func map(
        text: AttributedString,
        isFinal: Bool,
        context: TranscriptionContext,
        now: Date
    ) -> TranscriptEvent? {
        let plain = String(text.characters)
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard isFinal else { return .volatile(plain) }

        let timeRanges = text.runs.compactMap { $0[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] }
        return .finalized(TranscriptSegment(
            text: plain,
            audioStart: timeRanges.first.map(\.start.seconds),
            audioEnd: timeRanges.last.map(\.end.seconds),
            finalizedAt: now,
            locale: context.locale,
            source: context.source,
            sessionID: context.sessionID,
            sessionStartedAt: context.sessionStartedAt
        ))
    }
}
