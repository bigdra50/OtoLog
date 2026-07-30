import AppKit
import OtoLogCore
import SwiftUI

struct SettingsView: View {
    // MARK: Internal

    @Bindable var settings: AppSettings

    let coordinator: RecordingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("聞き取る言語", selection: $settings.localeIdentifier) {
                Text("自動検出").tag(AppSettings.autoRecognitionLocale)
                ForEach(recognitionChoices) { choice in
                    Text(choice.displayName).tag(choice.identifier)
                }
            }
            .pickerStyle(.menu)

            if settings.localeIdentifier == AppSettings.autoRecognitionLocale {
                detectionCandidates
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
        // 聞き取る言語が変わると訳せる相手も変わる（同じ言語は候補から消える）
        .task(id: settings.localeIdentifier) {
            // 自動検出では聞き取る言語が事前に決まらないので、候補の先頭を基準にする
            let source = settings.resolvedRecognitionLocales.first ?? settings.localeIdentifier
            translationTargets = await TranslationTargets.installed(for: source)
        }
        .task {
            recognitionChoices = await RecognitionLocales.supported()
            installedRecognitionChoices = await RecognitionLocales.installed()
        }
    }

    // MARK: Private

    @State private var loginItemEnabled = LoginItemManager.isEnabled
    @State private var loginItemError: String?
    @State private var translationTargets: [LanguageChoice] = []
    @State private var recognitionChoices: [LanguageChoice] = []
    @State private var installedRecognitionChoices: [LanguageChoice] = []

    private var systemTargetLabel: String {
        let code = Locale.current.language.languageCode?.identifier ?? ""
        guard let name = Locale.current.localizedString(forLanguageCode: code) else {
            return "システム設定に従う"
        }
        return "システム設定に従う（\(name)）"
    }

    /// 同じ言語どうしは翻訳できない。設定はできてしまうので気づけるようにする。
    /// 自動検出では聞き取る言語が事前に決まらないため出さない
    private var sameLanguageWarning: String? {
        guard settings.localeIdentifier != AppSettings.autoRecognitionLocale else { return nil }
        let source = Locale.Language(identifier: settings.localeIdentifier).languageCode?.identifier
        let target = Locale.Language(identifier: settings.resolvedTranslationTarget).languageCode?.identifier
        guard let source, let target, source == target else { return nil }
        return "翻訳先が聞き取る言語と同じため翻訳されません。"
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

    /// 自動検出で同時に走らせる言語を選ぶ。モデル DL 済みのものだけを出す
    private var detectionCandidates: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("検出候補（\(settings.recognitionCandidates.count) / \(RecognitionLocales.maximumCandidates)）")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(installedRecognitionChoices) { choice in
                        Toggle(choice.displayName, isOn: candidateBinding(choice.identifier))
                            .toggleStyle(.checkbox)
                            .disabled(isCandidateDisabled(choice.identifier))
                    }
                }
            }
            .frame(maxHeight: 96)
            Text("話されている言語をここから選びます。判定がつくまで数秒〜十数秒かかります。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func candidateBinding(_ identifier: String) -> Binding<Bool> {
        Binding {
            settings.recognitionCandidates.contains(identifier)
        } set: { isOn in
            var candidates = settings.recognitionCandidates
            if isOn {
                guard candidates.count < RecognitionLocales.maximumCandidates else { return }
                candidates.append(identifier)
            } else {
                candidates.removeAll { $0 == identifier }
            }
            settings.recognitionCandidates = candidates
        }
    }

    /// 上限まで選ばれていたら、未選択のものは触れないようにする
    private func isCandidateDisabled(_ identifier: String) -> Bool {
        !settings.recognitionCandidates.contains(identifier)
            && settings.recognitionCandidates.count >= RecognitionLocales.maximumCandidates
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
