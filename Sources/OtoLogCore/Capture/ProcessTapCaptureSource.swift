@preconcurrency import AVFAudio
import CoreAudio
import Foundation

// MARK: - ProcessTapCaptureSource

/// CoreAudio Process Tap（macOS 14.2+）によるシステム音声キャプチャ。
/// TCC は「システム音声の録音のみ」（NSAudioCaptureUsageDescription）で、画面収録の権限を要求しない。
/// 全プロセスのミックス（自プロセス除外のグローバルタップ）を private な aggregate device 経由で受け取る。
/// aggregate device の失効（構成変更等）は AsyncThrowingStream の throw として表面化し、
/// RecordingSession の自動再起動が受ける。
public final class ProcessTapCaptureSource: AudioCaptureSource, @unchecked Sendable {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public func start(targetFormat: AVAudioFormat) async throws -> AsyncThrowingStream<AudioChunk, any Error> {
        // 自プロセスの再生音を含めない（将来アプリが通知音等を出しても記録を汚さない）
        let selfObjectID = try? Self.processObjectID(forPID: ProcessInfo.processInfo.processIdentifier)
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: selfObjectID.map { [$0] } ?? []
        )
        description.name = "OtoLog System Audio Tap"
        description.isPrivate = true // 他プロセスの HAL からタップを見えなくする

        // TCC の「システム音声の録音」許可はここで要求される（未許可ならダイアログ、拒否済みなら失敗）
        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr,
              tapID != kAudioObjectUnknown
        else {
            throw CaptureError.systemAudioRecordingPermissionDenied
        }
        self.tapID = tapID

        do {
            let sourceFormat = try Self.tapFormat(of: tapID)

            var aggregateID = AudioObjectID(kAudioObjectUnknown)
            let aggregateStatus = AudioHardwareCreateAggregateDevice(
                Self.aggregateDescription(tapUUID: description.uuid) as CFDictionary, &aggregateID
            )
            guard aggregateStatus == noErr, aggregateID != kAudioObjectUnknown else {
                throw CaptureError.captureSetupFailed(status: aggregateStatus)
            }
            self.aggregateID = aggregateID

            let (stream, continuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
            self.continuation = continuation
            let converter = BufferConverter()

            var procID: AudioDeviceIOProcID?
            let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, sampleQueue) {
                [weak self] _, inInputData, _, _, _ in
                self?.deliver(
                    bufferList: inInputData, sourceFormat: sourceFormat,
                    targetFormat: targetFormat, converter: converter
                )
            }
            guard ioStatus == noErr, let procID else {
                throw CaptureError.captureSetupFailed(status: ioStatus)
            }
            self.procID = procID

            // aggregate の失効（まれな構成変更）を検知して再起動経路へ流す
            var aliveAddress = Self.aliveAddress
            let aliveStatus = AudioObjectAddPropertyListenerBlock(
                aggregateID, &aliveAddress, sampleQueue
            ) { [weak self] _, _ in
                guard let self, !self.isDeviceAlive() else { return }
                self.continuation?.finish(throwing: CaptureError.captureDeviceInvalidated)
            }
            aliveListenerInstalled = aliveStatus == noErr

            let startStatus = AudioDeviceStart(aggregateID, procID)
            guard startStatus == noErr else {
                throw CaptureError.captureSetupFailed(status: startStatus)
            }
            return stream
        } catch {
            await stop()
            throw error
        }
    }

    public func stop() async {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            if aliveListenerInstalled {
                var aliveAddress = Self.aliveAddress
                AudioObjectRemovePropertyListenerBlock(aggregateID, &aliveAddress, sampleQueue) { _, _ in }
                aliveListenerInstalled = false
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        continuation?.finish()
        continuation = nil
    }

    // MARK: Internal

    /// aggregate device の構成。private（他アプリの HAL に見せない）+ tap のみ + ドリフト補正。
    /// tapautostart により AudioDeviceStart 時に tap も自動で動き出す
    static func aggregateDescription(tapUUID: UUID) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "OtoLog Tap Device",
            kAudioAggregateDeviceUIDKey: "com.bigdra50.OtoLog.aggregate.\(tapUUID.uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]
    }

    // MARK: Private

    private static let aliveAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var continuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation?
    private var aliveListenerInstalled = false
    private let sampleQueue = DispatchQueue(label: "com.bigdra50.OtoLog.ProcessTapCapture")

    /// PID → CoreAudio プロセスオブジェクト ID（タップの除外リストは PID ではなくこの ID を取る）
    private static func processObjectID(forPID pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pidValue) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), pidPointer, &size, &objectID
            )
        }
        guard status == noErr, objectID != kAudioObjectUnknown else {
            throw CaptureError.captureSetupFailed(status: status)
        }
        return objectID
    }

    /// タップの出力フォーマット（全プロセスミックスの ASBD）
    private static func tapFormat(of tapID: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CaptureError.captureSetupFailed(status: status)
        }
        return format
    }

    /// サンプル型（Float32/Int16）に依存しないよう audioBufferList を丸ごと複製する
    private static func ownedCopy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in 0..<sourceBuffers.count {
            guard let source = sourceBuffers[index].mData,
                  let destination = destinationBuffers[index].mData else { return nil }
            let bytes = min(sourceBuffers[index].mDataByteSize, destinationBuffers[index].mDataByteSize)
            memcpy(destination, source, Int(bytes))
            destinationBuffers[index].mDataByteSize = bytes
        }
        return copy
    }

    private func isDeviceAlive() -> Bool {
        var address = Self.aliveAddress
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &alive)
        return status == noErr && alive != 0
    }

    /// IOProc からの AudioBufferList を targetFormat のチャンクへ変換して流す。
    /// bufferList の実体はコールバック外で無効なため、所有コピーへ差し替えてから yield する
    private func deliver(
        bufferList: UnsafePointer<AudioBufferList>,
        sourceFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        converter: BufferConverter
    ) {
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            bufferListNoCopy: bufferList
        ), sourceBuffer.frameLength > 0 else { return }

        guard let converted = converter.convert(sourceBuffer, to: targetFormat) else { return }
        let owned = (converted === sourceBuffer) ? Self.ownedCopy(of: converted) : converted
        if let owned {
            continuation?.yield(AudioChunk(buffer: owned))
        }
    }
}

// MARK: - CaptureError

public enum CaptureError: Error, LocalizedError {
    case systemAudioRecordingPermissionDenied
    case captureSetupFailed(status: OSStatus)
    case captureDeviceInvalidated

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case .systemAudioRecordingPermissionDenied:
            "システム音声の録音の許可が必要です。システム設定 > プライバシーとセキュリティ > 画面収録とシステム音声録音 で OtoLog を許可し、アプリを再起動してください。"
        case let .captureSetupFailed(status):
            "音声キャプチャの初期化に失敗しました（OSStatus \(status)）"
        case .captureDeviceInvalidated:
            "音声キャプチャデバイスが無効になりました（オーディオ構成の変更）。記録を再開してください。"
        }
    }
}
