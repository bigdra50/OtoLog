@preconcurrency import AVFAudio
import Foundation

/// 音声チャンク列を文字起こしイベント列へ変換するエンジン。
/// Speech フレームワークへの依存は実装側に閉じ、コントラクトには漏らさない。
public protocol TranscriptionEngine: Sendable {
    /// ロケール検証・アセット予約・必要ならモデルダウンロード（進捗通知）を行い、
    /// キャプチャ側へ渡す解析フォーマットを返す。
    ///
    /// locales を複数渡すと並行して認識し、話されている言語を選んで1つに絞る。
    /// 判定がつくまでの結果は保留され、決まった時点でまとめて流れる
    func prepare(locales: [Locale], onProgress: @escaping @Sendable (Double) -> Void) async throws -> AVAudioFormat

    /// チャンクの消費を開始し、イベント列を返す。1セッション1回。
    /// context はセッション側が発行し、確定セグメントへそのまま転写される。
    func start(
        chunks: AsyncThrowingStream<AudioChunk, any Error>,
        context: TranscriptionContext
    ) async throws -> AsyncThrowingStream<TranscriptEvent, any Error>

    /// 入力終了を確定し、残りの結果をすべて吐き出させる。
    func finish() async
}
