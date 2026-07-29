import CoreAudio
import Foundation
@testable import OtoLogCore
import Testing

/// 実タップ（TCC + 実ハードウェア必須）は起動できないため、
/// テスト対象は aggregate device 構成の契約に限る。実動作は手動検証（README 参照）
struct ProcessTapCaptureSourceTests {
    /// private な tap-only aggregate + ドリフト補正 + 自動開始、という構成の固定。
    /// この構成が崩れると他アプリへの露出・無音・開始漏れにつながる
    @Test func aggregateDescriptionIsPrivateTapOnlyWithDriftCompensation() throws {
        let uuid = UUID()
        let description = ProcessTapCaptureSource.aggregateDescription(tapUUID: uuid)

        #expect(description[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
        #expect(description[kAudioAggregateDeviceTapAutoStartKey] as? Bool == true)
        #expect((description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])?.isEmpty == true)
        #expect((description[kAudioAggregateDeviceUIDKey] as? String)?.contains(uuid.uuidString) == true)

        let taps = try #require(description[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        #expect(taps.count == 1)
        #expect(taps[0][kAudioSubTapUIDKey] as? String == uuid.uuidString)
        #expect(taps[0][kAudioSubTapDriftCompensationKey] as? Bool == true)
    }
}
