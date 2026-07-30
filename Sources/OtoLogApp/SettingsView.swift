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

            Toggle("翻訳する", isOn: $settings.translationEnabled)
                .toggleStyle(.switch)

            if settings.translationEnabled {
                Picker("翻訳先", selection: $settings.translationTargetIdentifier) {
                    Text(systemTargetLabel).tag(AppSettings.systemTranslationTarget)
                    ForEach(translationTargets) { target in
                        Text(target.displayName).tag(target.identifier)
                    }
                }
                .pickerStyle(.menu)

                Toggle("画面に字幕を表示", isOn: $settings.subtitleOverlayEnabled)
                    .toggleStyle(.switch)

                if let sameLanguageWarning {
                    Text(sameLanguageWarning)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                // 未 DL の言語は候補に出せない（直接生成したセッションからは DL を要求できない）
                Text("他の言語はシステム設定 > 一般 > 言語と地域 > 翻訳言語 で追加できます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
        // 認識言語が変わると訳せる相手も変わる（同じ言語は候補から消える）
        .task(id: settings.localeIdentifier) {
            translationTargets = await TranslationTargets.installed(for: settings.localeIdentifier)
        }
    }

    // MARK: Private

    @State private var loginItemEnabled = LoginItemManager.isEnabled
    @State private var loginItemError: String?
    @State private var translationTargets: [TranslationTarget] = []

    private var systemTargetLabel: String {
        let code = Locale.current.language.languageCode?.identifier ?? ""
        guard let name = Locale.current.localizedString(forLanguageCode: code) else {
            return "システム設定に従う"
        }
        return "システム設定に従う（\(name)）"
    }

    /// 認識言語と同じ言語は翻訳できない。設定できてしまうので気づけるようにする
    private var sameLanguageWarning: String? {
        let source = Locale.Language(identifier: settings.localeIdentifier).languageCode?.identifier
        let target = Locale.Language(identifier: settings.resolvedTranslationTarget).languageCode?.identifier
        guard let source, let target, source == target else { return nil }
        return "翻訳先が認識言語と同じため翻訳されません。"
    }

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
