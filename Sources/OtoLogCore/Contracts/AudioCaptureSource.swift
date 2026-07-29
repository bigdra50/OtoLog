@preconcurrency import AVFAudio
import Foundation

// MARK: - AudioChunk

/// 変換済み音声チャンク。
/// AVAudioPCMBuffer は Sendable でないため、「yield 後にバッファへ書き込まない」
/// 所有権規約のもとで @unchecked Sendable として運ぶ（yap と同じ現実解）。
public struct AudioChunk: @unchecked Sendable {
    // MARK: Lifecycle

    public init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    // MARK: Public

    public let buffer: AVAudioPCMBuffer
}

// MARK: - AudioCaptureSource

/// 音声入力源。システム音声 / マイク / ファイルを同じ形で差し替えられるようにする。
public protocol AudioCaptureSource: Sendable {
    /// targetFormat へ変換済みのチャンク列を返す。
    /// 正常な stop() でストリームは finish し、割り込み（スリープ等）では throw で終わる。
    func start(targetFormat: AVAudioFormat) async throws -> AsyncThrowingStream<AudioChunk, any Error>
    func stop() async
}
