import CoreAudio
import Foundation

// MARK: - MicrophoneDevice

/// マイク選択 UI に出す1デバイス。UID は再起動を跨いでも安定する識別子
public struct MicrophoneDevice: Identifiable, Sendable, Equatable {
    public let uid: String
    public let name: String

    public var id: String {
        uid
    }
}

// MARK: - MicrophoneDeviceCatalog

/// Core Audio HAL の入力デバイス列挙。列挙だけなら TCC の許可ダイアログは出ない。
public enum MicrophoneDeviceCatalog {
    // MARK: Public

    /// 入力ストリームを持つデバイスの一覧（システムの並び順のまま）
    public static func availableInputs() -> [MicrophoneDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }
        var deviceIDs = [AudioDeviceID](
            repeating: AudioDeviceID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard hasInputStreams(deviceID),
                  let uid = stringProperty(of: deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(of: deviceID, selector: kAudioObjectPropertyName)
            else { return nil }
            return MicrophoneDevice(uid: uid, name: name)
        }
    }

    /// UID → デバイス ID。抜かれたデバイスの UID では captureSetupFailed になる
    public static func deviceID(forUID uid: String) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw CaptureError.captureSetupFailed(status: status)
        }
        return deviceID
    }

    // MARK: Private

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        return status == noErr && size > 0
    }

    private static func stringProperty(
        of deviceID: AudioDeviceID, selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
