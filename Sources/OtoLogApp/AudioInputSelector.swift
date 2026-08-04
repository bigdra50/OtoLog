import OtoLogCore
import SwiftUI

/// 録音開始前に音源（システム音声 / マイク）と使用マイクを選ぶ行。
/// 選択は設定として永続化され、次の記録開始から反映される。
struct AudioInputSelector: View {
    // MARK: Internal

    @Bindable var settings: AppSettings

    let isRecording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: $settings.audioInputMode) {
                ForEach(AudioInputMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            } label: {
                Label("入力", systemImage: "waveform.badge.mic")
            }
            .pickerStyle(.menu)

            if settings.audioInputMode.usesMicrophone {
                Picker(selection: $settings.microphoneDeviceUID) {
                    Text("システム既定のマイク").tag(String?.none)
                    ForEach(microphones) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                    // 抜かれたマイクの選択は残す（繋ぎ直せばそのまま使われる）。
                    // 記録開始時に未接続のままならシステム既定へフォールバックする
                    if let uid = settings.microphoneDeviceUID,
                       !microphones.contains(where: { $0.uid == uid }) {
                        Text("未接続のマイク").tag(String?.some(uid))
                    }
                } label: {
                    Label("マイク", systemImage: "mic")
                }
                .pickerStyle(.menu)
            }
        }
        .font(.caption)
        // 記録中の入力切替は対応しない（次のセッションから反映）
        .disabled(isRecording)
        .help(isRecording ? "記録中は変更できません（次の記録から反映されます）" : "記録する音源を選ぶ")
        .onAppear { microphones = MicrophoneDeviceCatalog.availableInputs() }
    }

    // MARK: Private

    @State private var microphones: [MicrophoneDevice] = []
}
