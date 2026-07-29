import AppKit
import OtoLogCore
import SwiftUI

struct SettingsView: View {
    // MARK: Internal

    @Bindable var settings: AppSettings

    let coordinator: RecordingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("言語", selection: $settings.localeIdentifier) {
                ForEach(localeChoices, id: \.self) { identifier in
                    Text(displayName(for: identifier)).tag(identifier)
                }
            }
            .pickerStyle(.menu)

            HStack(spacing: 4) {
                Text("保存先")
                Text(settings.saveDirectoryPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                IconButton(systemImage: "folder", label: "保存先を変更…") { chooseDirectory() }
            }

            HStack {
                Text("claude パス")
                TextField("~/.local/bin/claude", text: $settings.claudeExecutablePath)
                    .textFieldStyle(.roundedBorder)
            }

            Picker("停止時の自動処理", selection: $settings.postStopAction) {
                ForEach(PostStopAction.allCases, id: \.self) { action in
                    Text(action.displayName).tag(action)
                }
            }
            .pickerStyle(.menu)

            if settings.postStopAction == .titleAndPipeline {
                Picker("自動実行プレイブック", selection: $settings.defaultPlaybookID) {
                    Text("内容から自動判定").tag(AppSettings.autoPlaybookID)
                    ForEach(PlaybookStore().loadPlaybooks()) { playbook in
                        Text(playbook.displayName).tag(playbook.id)
                    }
                }
                .pickerStyle(.menu)
            }

            Toggle("ログイン時に起動", isOn: loginItemBinding)
                .toggleStyle(.switch)

            if let loginItemError {
                Text(loginItemError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
        .panelBackground()
    }

    // MARK: Private

    @State private var loginItemEnabled = LoginItemManager.isEnabled
    @State private var loginItemError: String?

    /// MVP は主要ロケールのみ。全対応ロケールの列挙は将来 SpeechTranscriber.supportedLocales から
    private var localeChoices: [String] {
        var choices = ["ja-JP", "en-US"]
        if !choices.contains(settings.localeIdentifier) {
            choices.append(settings.localeIdentifier)
        }
        return choices
    }

    private var loginItemBinding: Binding<Bool> {
        Binding {
            loginItemEnabled
        } set: { newValue in
            do {
                try LoginItemManager.setEnabled(newValue)
                loginItemEnabled = newValue
                loginItemError = nil
            } catch {
                loginItemError = "ログイン項目の変更に失敗: \(error.localizedDescription)"
                loginItemEnabled = LoginItemManager.isEnabled
            }
        }
    }

    private func displayName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.updateSaveDirectory(url)
        }
    }
}
