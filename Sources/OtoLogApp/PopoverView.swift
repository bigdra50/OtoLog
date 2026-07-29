import OtoLogCore
import SwiftUI

/// ポップオーバーの中身。表示と操作の転送のみでロジックは持たない。
struct PopoverView: View {
    // MARK: Internal

    let state: AppState
    let settings: AppSettings
    let coordinator: RecordingCoordinator
    let generation: GenerationCoordinator
    let pipeline: PipelineCoordinator
    let openLibrary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { generation.refreshSteward() }
    }

    // MARK: Private

    private enum GenerationMode {
        case single
        case playbook
    }

    @State private var showsSettings = false
    @State private var showsGeneration = false
    @State private var generationMode = GenerationMode.single
    @State private var selectedSessionID = ""
    @State private var selectedTemplateID = ""
    @State private var selectedPlaybookID = ""
    @State private var briefTopic = ""

    private var statusText: String {
        switch state.sessionState {
        case .idle: "待機中"
        case .preparing: "準備中"
        case .recording: "記録中"
        case .stopping: "停止中"
        case .failed: "エラー"
        }
    }

    private var statusSymbol: String {
        switch state.sessionState {
        case .recording: "waveform"
        case .failed: "exclamationmark.triangle"
        default: "ear"
        }
    }

    private var selectedSession: SessionRef? {
        state.generationSessions.first { $0.id == selectedSessionID }
    }

    private var header: some View {
        HStack {
            Label(statusText, systemImage: statusSymbol)
                .font(.headline)
            Spacer()
            Button(state.isRecording ? "停止" : "開始") {
                coordinator.toggle()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var content: some View {
        switch state.sessionState {
        case .preparing:
            ProgressView(value: state.preparationProgress) {
                Text("音声認識モデルを準備中…")
                    .font(.caption)
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                HStack {
                    Button("システム設定を開く") { coordinator.openScreenRecordingSettings() }
                    Button("アプリを再起動") { coordinator.relaunchApp() }
                }
                .font(.caption)
            }
        default:
            transcriptArea
        }
    }

    private var transcriptArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.liveText.isEmpty, state.lastSegmentText.isEmpty {
                Text(state.isRecording ? "聞き取り中…" : "開始するとここにライブ字幕が流れます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if !state.lastSegmentText.isEmpty {
                    Text(state.lastSegmentText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !state.liveText.isEmpty {
                    Text(state.liveText)
                        .font(.body)
                        .lineLimit(3)
                }
            }
            if let storeError = state.storeErrorMessage {
                Text("保存エラー: \(storeError)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !state.stewardFindings.isEmpty || state.pipelineRunning {
                stewardRow
            }
            HStack {
                Button("ライブラリ") { openLibrary() }
                Button("最新の記録を開く") { coordinator.openLatestSession() }
                Spacer()
                Button(showsGeneration ? "生成を閉じる" : "生成") {
                    toggleGeneration()
                }
                Button(showsSettings ? "設定を閉じる" : "設定") {
                    showsSettings.toggle()
                }
            }
            .font(.caption)
            if showsGeneration {
                generationSection
            }
            if showsSettings {
                SettingsView(settings: settings, coordinator: coordinator)
            }
            HStack {
                Spacer()
                Button("OtoLog を終了") { NSApp.terminate(nil) }
                    .font(.caption2)
            }
        }
    }

    private var generationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.generationSessions.isEmpty {
                Text("記録がまだありません")
                    .foregroundStyle(.secondary)
            } else {
                Picker("対象", selection: $selectedSessionID) {
                    ForEach(state.generationSessions) { session in
                        Text("\(shortDate(session.startedAt)) \(session.displayName)").tag(session.id)
                    }
                }
                .pickerStyle(.menu)
                Picker("", selection: $generationMode) {
                    Text("単発").tag(GenerationMode.single)
                    Text("プレイブック").tag(GenerationMode.playbook)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch generationMode {
                case .single:
                    Picker("テンプレート", selection: $selectedTemplateID) {
                        ForEach(state.generationTemplates) { template in
                            Text(template.displayName).tag(template.id)
                        }
                    }
                    .pickerStyle(.menu)
                    generationControls
                case .playbook:
                    Picker("プレイブック", selection: $selectedPlaybookID) {
                        ForEach(state.pipelinePlaybooks) { playbook in
                            Text(playbook.displayName).tag(playbook.id)
                        }
                    }
                    .pickerStyle(.menu)
                    pipelineControls
                }
                Divider()
                // これから聞くセッションの予習（過去の記録から文脈ノートを作る）
                HStack(spacing: 6) {
                    TextField("トピック（任意）", text: $briefTopic)
                        .textFieldStyle(.roundedBorder)
                    Button("事前ブリーフ") {
                        generation.generateBrief(topic: briefTopic.isEmpty ? nil : briefTopic)
                    }
                }
            }
        }
        .font(.caption)
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        .onChange(of: state.generationSessions) { _, sessions in
            reconcileSelection(with: sessions)
        }
        .onChange(of: selectedSessionID) { _, _ in
            if let session = selectedSession {
                pipeline.loadStates(for: session)
            }
        }
    }

    @ViewBuilder private var pipelineControls: some View {
        if !state.pipelineTasks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(state.pipelineTasks) { task in
                    pipelineTaskRow(task)
                }
            }
        }
        if state.pipelineRunning {
            HStack {
                Spacer()
                Button("キャンセル") { pipeline.cancel() }
            }
        } else {
            HStack {
                Button("プレイブックを実行") { runSelectedPlaybook(only: nil) }
                    .disabled(state.isRecording || selectedSession == nil)
                if state.pipelineTasks.contains(where: { $0.state.status == .failed }) {
                    Button("失敗を再実行") { retryFailedTasks() }
                }
            }
            if state.isRecording {
                Text("記録停止後に実行できます")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var generationControls: some View {
        switch state.generationState {
        case .idle:
            HStack {
                Button("生成を実行") { runSelectedGeneration() }
                if selectedSession?.title == nil {
                    Button("タイトル生成") { runTitleAssignment() }
                }
            }
        case let .running(templateName):
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("\(templateName) を生成中…")
                Spacer()
                Button("キャンセル") { generation.cancel() }
            }
        case let .finished(url):
            HStack {
                Label(url.lastPathComponent, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("開く") { generation.openResult(url) }
                Button("再実行") { runSelectedGeneration() }
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                Button("再実行") { runSelectedGeneration() }
            }
        }
    }

    /// 生成セクションを開いていなくても処理の進捗・失敗が見えるよう、行内に状態を出す
    private var stewardRow: some View {
        HStack(spacing: 6) {
            if case let .running(name) = state.generationState {
                ProgressView()
                    .controlSize(.mini)
                Text("\(name) を実行中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if state.pipelineRunning {
                ProgressView()
                    .controlSize(.mini)
                Text("パイプラインを実行中…（詳細は「生成」）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case let .failed(message) = state.generationState {
                Text("処理に失敗: \(message)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Spacer()
                Button("再試行") { generation.processNextUnprocessed() }
                    .font(.caption)
            } else {
                Text("未処理の記録が \(state.stewardFindings.count) 件あります")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
                Button("処理") { generation.processNextUnprocessed() }
                    .font(.caption)
            }
        }
    }

    private func pipelineTaskRow(_ task: PipelineTaskDisplay) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                switch task.state.status {
                case .pending:
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                case .running:
                    ProgressView()
                        .controlSize(.mini)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case .skipped:
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                }
                Text(task.displayName)
                Spacer()
                if task.state.status == .failed, let error = task.state.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            // 生成中の claude の出力/thinking の末尾。動いていることの生存確認
            if task.state.status == .running, let snippet = task.snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .padding(.leading, 20)
            }
        }
    }

    private func toggleGeneration() {
        showsGeneration.toggle()
        guard showsGeneration else { return }
        generation.refresh()
        pipeline.refresh()
        reconcileSelection(with: state.generationSessions)
        if selectedTemplateID.isEmpty || !state.generationTemplates.contains(where: { $0.id == selectedTemplateID }) {
            selectedTemplateID = state.generationTemplates.first?.id ?? ""
        }
        if selectedPlaybookID.isEmpty || !state.pipelinePlaybooks.contains(where: { $0.id == selectedPlaybookID }) {
            selectedPlaybookID = state.pipelinePlaybooks.first?.id ?? ""
        }
        if let session = selectedSession {
            pipeline.loadStates(for: session)
        }
    }

    private func runSelectedPlaybook(only: [String]?) {
        guard let session = selectedSession,
              let playbook = state.pipelinePlaybooks.first(where: { $0.id == selectedPlaybookID })
        else { return }
        pipeline.run(playbook: playbook, session: session, only: only)
    }

    private func retryFailedTasks() {
        guard let session = selectedSession,
              let playbook = state.pipelinePlaybooks.first(where: { $0.id == selectedPlaybookID })
        else { return }
        pipeline.retryFailed(playbook: playbook, session: session)
    }

    /// タイトル付与のリネーム等で一覧が変わったとき、選択が消えたら先頭へ戻す
    private func reconcileSelection(with sessions: [SessionRef]) {
        if !sessions.contains(where: { $0.id == selectedSessionID }) {
            selectedSessionID = sessions.first?.id ?? ""
        }
    }

    private func runTitleAssignment() {
        guard let session = selectedSession else { return }
        generation.assignTitle(session: session)
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    private func runSelectedGeneration() {
        guard let session = state.generationSessions.first(where: { $0.id == selectedSessionID }),
              let template = state.generationTemplates.first(where: { $0.id == selectedTemplateID })
        else { return }
        generation.generate(session: session, template: template)
    }
}
