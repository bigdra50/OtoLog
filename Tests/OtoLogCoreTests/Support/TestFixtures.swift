import Foundation
@testable import OtoLogCore

enum TestFixtures {
    static func segment(
        text: String,
        finalizedAt: Date = Date(timeIntervalSince1970: 1_785_297_600),
        source: AudioSourceKind = .system
    ) -> TranscriptSegment {
        TranscriptSegment(
            text: text,
            audioStart: nil,
            audioEnd: nil,
            finalizedAt: finalizedAt,
            locale: "ja-JP",
            source: source,
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sessionStartedAt: finalizedAt
        )
    }
}
