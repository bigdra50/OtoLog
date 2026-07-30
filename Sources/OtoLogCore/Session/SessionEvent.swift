import Foundation

// MARK: - SessionState

public enum SessionState: Sendable, Equatable {
    case idle
    case preparing
    case recording
    case stopping
    case failed(String)
}

// MARK: - SessionEvent

/// RecordingSession が UI へ流す単一消費者向けイベント。
public enum SessionEvent: Sendable, Equatable {
    case stateChanged(SessionState)
    case preparationProgress(Double)
    /// volatile 結果。表示のみでストレージへは行かない
    case liveTranscript(String)
    case segmentRecorded(TranscriptSegment)
    /// 保存失敗。セッション自体は継続する
    case storeError(String)
    /// 翻訳失敗。原文だけが保存され、セッション自体は継続する
    case translationError(String)
    /// 停止完了（全セグメント保存済み）。タイトル生成やパイプラインの起点
    case sessionFinished(SessionRef)
}
