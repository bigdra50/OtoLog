import Foundation

// MARK: - AudioSourceKind

public enum AudioSourceKind: String, Sendable, Codable {
    case system
    case microphone
}

// MARK: - TranscriptEvent

/// エンジンが流す文字起こしイベント。
/// volatile は UI のライブ表示専用で、ストレージへは finalized のみが行く。
public enum TranscriptEvent: Sendable, Equatable {
    case volatile(String)
    case finalized(TranscriptSegment)
}

// MARK: - TranscriptSegment

/// 確定済みの文字起こし1区間。ストレージへ書かれる最小単位。
public struct TranscriptSegment: Sendable, Equatable, Codable {
    // MARK: Lifecycle

    public init(
        text: String,
        audioStart: TimeInterval?,
        audioEnd: TimeInterval?,
        finalizedAt: Date,
        locale: String,
        source: AudioSourceKind,
        sessionID: UUID,
        sessionStartedAt: Date
    ) {
        self.text = text
        self.audioStart = audioStart
        self.audioEnd = audioEnd
        self.finalizedAt = finalizedAt
        self.locale = locale
        self.source = source
        self.sessionID = sessionID
        self.sessionStartedAt = sessionStartedAt
    }

    // MARK: Public

    public var text: String
    /// アナライザ開始からの相対秒。audioTimeRange 属性が無い場合は nil
    public var audioStart: TimeInterval?
    public var audioEnd: TimeInterval?
    /// 壁時計。md のタイムスタンプと日付ロールオーバーの基準
    public var finalizedAt: Date
    public var locale: String
    public var source: AudioSourceKind
    /// 後処理で絶対時刻を復元できるようセッション情報を持たせる
    public var sessionID: UUID
    public var sessionStartedAt: Date
}
