import Foundation

// MARK: - TranscriptionContext

/// 1記録セッションの識別情報。RecordingSession が発行し、エンジン（セグメントへの転写）と
/// ストア（保存先ディレクトリの決定）の両方に配られる。
public struct TranscriptionContext: Sendable, Equatable {
    // MARK: Lifecycle

    public init(locale: String, source: AudioSourceKind, sessionID: UUID, sessionStartedAt: Date) {
        self.locale = locale
        self.source = source
        self.sessionID = sessionID
        self.sessionStartedAt = sessionStartedAt
    }

    // MARK: Public

    public var locale: String
    public var source: AudioSourceKind
    public var sessionID: UUID
    public var sessionStartedAt: Date
}
