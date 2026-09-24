import Foundation

// MARK: - SessionState

public enum SessionState: Sendable, Equatable {
    case idle
    case preparing
    case recording
    /// 閉じている途中。停止と無音での自動停止、保存先を確保した後の失敗は、閉じ終えるまでここを通る
    case stopping
    /// 失敗で終わった。値はポップオーバーに出す理由
    case failed(String)
}

// MARK: - CaptureInterruption

/// 記録中にキャプチャが止まったこと。どの音源が・なぜ止まり・再起動したかを後から追えるようにする
public struct CaptureInterruption: Sendable, Equatable {
    // MARK: Lifecycle

    public init(source: AudioSourceKind, reason: String, restartAttempt: Int?) {
        self.source = source
        self.reason = reason
        self.restartAttempt = restartAttempt
    }

    // MARK: Public

    public let source: AudioSourceKind
    /// 音源名を付けない元の理由。音源は source で表す
    public let reason: String
    /// この中断を受けて行う再起動が連続何回目か（1始まり）。nil はセッションが再起動を諦めたこと
    public let restartAttempt: Int?
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
    /// 起動の途中か記録中のキャプチャの中断。再起動して続く場合も諦める場合も、中断のたびに1回流れる。
    /// 起動の途中の中断もその時点で流れ、再起動は記録が始まってから行う
    case captureInterrupted(CaptureInterruption)
    /// 無音が silence（start に渡した silenceTimeout）続いたため、記録を閉じ始める。
    /// 続いて停止と同じく stopping・sessionFinished・idle が流れる
    case autoStopped(silence: Duration)
    /// 記録を閉じた（全セグメント保存済み）。タイトル生成やパイプラインの起点。
    /// 停止と無音での自動停止では毎回、失敗では1件以上保存できたときだけ流れる
    case sessionFinished(SessionRef)
}
