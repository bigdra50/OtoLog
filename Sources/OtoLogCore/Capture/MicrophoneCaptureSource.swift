@preconcurrency import AVFAudio
import AVFoundation
import Foundation

/// AVAudioEngine の入力ノードによるマイクキャプチャ。
/// enablesEchoCancellation で Apple の voice processing（AEC + ノイズ抑制）を有効化し、
/// スピーカー再生（会議相手の声）がマイクへ回り込んで二重記録される問題を抑える。
/// デバイス抜去などの構成変更は AsyncThrowingStream の throw として表面化し、
/// RecordingSession の自動再起動が受ける。
public final class MicrophoneCaptureSource: AudioCaptureSource, @unchecked Sendable {
    // MARK: Lifecycle

    /// deviceUID が nil ならシステム既定の入力デバイスを使う
    public init(deviceUID: String? = nil, enablesEchoCancellation: Bool = true) {
        self.deviceUID = deviceUID
        self.enablesEchoCancellation = enablesEchoCancellation
    }

    // MARK: Public

    public func start(targetFormat: AVAudioFormat) async throws -> AsyncThrowingStream<AudioChunk, any Error> {
        // 初回はここで TCC のマイク許可ダイアログが出る（Info.plist の NSMicrophoneUsageDescription 必須）
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw CaptureError.microphonePermissionDenied
        }

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        // 指定マイクが見つからない（抜かれている）ときはシステム既定で録り続ける方を優先する。
        // 解決できたのに設定できないのは異常なので、そちらは throw のまま
        if let deviceUID, let deviceID = try? MicrophoneDeviceCatalog.deviceID(forUID: deviceUID) {
            try input.auAudioUnit.setDeviceID(deviceID)
        }
        if enablesEchoCancellation {
            // タップ設置・engine.start の後では切り替えられないため最初に行う。
            // 対応しないデバイスでの失敗は握って素のマイクで続ける（AEC は品質向上であって前提ではない）
            try? input.setVoiceProcessingEnabled(true)
            // 通話向けの自動ダッキングは他アプリの再生（記録対象そのもの）を静かにしてしまうので切る
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false, duckingLevel: .min
            )
        }

        let (stream, continuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        lock.withLock { self.continuation = continuation }
        let converter = BufferConverter()
        let tapFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // タップ所有のバッファは yield 後に再利用され得るため、常に所有コピーへ変換して流す
            if let owned = converter.convertOwned(buffer, to: targetFormat) {
                currentContinuation?.yield(AudioChunk(buffer: owned))
            }
        }
        // デバイス抜去・入出力構成の変更は一過性障害としてセッション側の再起動に委ねる
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.currentContinuation?.finish(throwing: CaptureError.captureDeviceInvalidated)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            await stop()
            throw CaptureError.captureSetupFailed(status: OSStatus((error as NSError).code))
        }
        return stream
    }

    public func stop() async {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        let continuation = lock.withLock {
            let held = self.continuation
            self.continuation = nil
            return held
        }
        continuation?.finish()
    }

    // MARK: Private

    private let deviceUID: String?
    private let enablesEchoCancellation: Bool
    /// タップコールバック（オーディオスレッド）と stop の競合から continuation を守る
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var continuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation?
    private var observer: NSObjectProtocol?

    private var currentContinuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation? {
        lock.withLock { continuation }
    }
}
