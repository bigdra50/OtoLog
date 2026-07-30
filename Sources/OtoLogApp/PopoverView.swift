import OtoLogCore
import SwiftUI

/// ポップオーバーの中身。表示と操作の転送のみでロジックは持たない。
struct PopoverView: View {
    // MARK: Lifecycle

    /// showsGeneration / showsSettings は展開状態の初期値。
    /// 最も背が高くなる組み合わせをレイアウト検証から再現できるようにするため外から与える
    init(
        state: AppState,
        settings: AppSettings,
        coordinator: RecordingCoordinator,
        generation: GenerationCoordinator,
        pipeline: PipelineCoordinator,
        openLibrary: @escaping () -> Void,
        showsGeneration: Bool = false,
        showsSettings: Bool = false,
        generationMode: GenerationMode = .single
    ) {
        self.state = state
        self.settings = settings
        self.coordinator = coordinator
        self.generation = generation
        self.pipeline = pipeline
        self.openLibrary = openLibrary
        _showsGeneration = State(initialValue: showsGeneration)
        _showsSettings = State(initialValue: showsSettings)
        _generationMode = State(initialValue: generationMode)
    }

    // MARK: Internal

    enum GenerationMode {
        case single
        case playbook
    }

    let state: AppState
    let settings: AppSettings
    let coordinator: RecordingCoordinator
    let generation: GenerationCoordinator
    let pipeline: PipelineCoordinator
    let openLibrary: () -> Void

    var body: some View {
        // 高さは中身のなりゆきに任せる。NSPopover は提案サイズを与えないため、
        // ここで maxHeight や ScrollView を挟むと SwiftUI 側が高さを決めきれず
        // 中身が短くても余白が出たり、逆に切り詰められたりする。
        // 画面からのはみ出しは AppKit 側（StatusItemController）で面倒を見る
        stack
            .task { await generation.refreshSteward() }
    }

    // MARK: Private

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
        case .preparing: "arrow.down.circle"
        case .failed: "exclamationmark.triangle"
        default: "ear"
        }
    }

    private var statusTint: AnyShapeStyle {
        switch state.sessionState {
        case .recording: AnyShapeStyle(.red)
        case .failed: AnyShapeStyle(.orange)
        default: AnyShapeStyle(.secondary)
        }
    }

    private var selectedSession: SessionRef? {
        state.generationSessions.first { $0.id == selectedSessionID }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            Divider()
            footer
        }
        .padding(16)
        .frame(width: PopoverMetrics.width)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(statusTint)
                .symbolEffect(.variableColor.iterative, isActive: state.isRecording)
                .frame(width: 18)
            Text(statusText)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(state.isRecording ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            Spacer(minLength: 8)
            RecordButton(isRecording: state.isRecording) { coordinator.toggle() }
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
                // 復旧操作は頻度が低く取り違えの影響も大きいので、ここだけは文言を残す
                HStack(spacing: 8) {
                    Button {
                        coordinator.openScreenRecordingSettings()
                    } label: {
                        Label("システム設定", systemImage: "gearshape")
                    }
                    Button {
                        coordinator.relaunchApp()
                    } label: {
                        Label("再起動", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
                Label("保存エラー: \(storeError)", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !state.stewardFindings.isEmpty || state.pipelineRunning {
                stewardRow
            }
            toolbar
            if showsGeneration {
                generationSection
            }
            if showsSettings {
                SettingsView(settings: settings, coordinator: coordinator)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            IconButton(systemImage: "books.vertical", label: "ライブラリ") { openLibrary() }
            IconButton(systemImage: "doc.text", label: "最新の記録を開く") { coordinator.openLatestSession() }
            Spacer()
            IconButton(
                systemImage: "sparkles",
                label: showsGeneration ? "生成を閉じる" : "生成",
                isOn: showsGeneration
            ) {
                toggleGeneration()
            }
            IconButton(
                systemImage: "gearshape",
                label: showsSettings ? "設定を閉じる" : "設定",
                isOn: showsSettings
            ) {
                showsSettings.toggle()
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
                    IconButton(systemImage: "wand.and.stars", label: "事前ブリーフを作成", tone: .accent) {
                        generation.generateBrief(topic: briefTopic.isEmpty ? nil : briefTopic)
                    }
                }
            }
        }
        .font(.caption)
        .panelBackground()
        .onChange(of: state.generationSessions) { _, sessions in
            reconcileSelection(with: sessions)
        }
        .onChange(of: selectedSessionID) { _, _ in
            if let session = selectedSession {
                Task { await pipeline.loadStates(for: session) }
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
        HStack(spacing: 2) {
            if state.isRecording, !state.pipelineRunning {
                Text("記録停止後に実行できます")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer()
            if state.pipelineRunning {
                IconButton(systemImage: "xmark", label: "実行をキャンセル", tone: .destructive) { pipeline.cancel() }
            } else {
                if state.pipelineTasks.contains(where: { $0.state.status == .failed }) {
                    IconButton(systemImage: "arrow.clockwise", label: "失敗したタスクを再実行") { retryFailedTasks() }
                }
                IconButton(systemImage: "play.fill", label: "プレイブックを実行", tone: .accent) {
                    runSelectedPlaybook(only: nil)
                }
                .disabled(state.isRecording || selectedSession == nil)
            }
        }
    }

    @ViewBuilder private var generationControls: some View {
        switch state.generationState {
        case .idle:
            HStack(spacing: 2) {
                Spacer()
                if selectedSession?.title == nil {
                    IconButton(systemImage: "text.badge.plus", label: "タイトルを生成") { runTitleAssignment() }
                }
                IconButton(systemImage: "play.fill", label: "生成を実行", tone: .accent) { runSelectedGeneration() }
            }
        case let .running(templateName):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("\(templateName) を生成中…")
                    .foregroundStyle(.secondary)
                Spacer()
                IconButton(systemImage: "xmark", label: "生成をキャンセル", tone: .destructive) { generation.cancel() }
            }
        case let .finished(url):
            HStack(spacing: 2) {
                Label(url.lastPathComponent, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                IconButton(systemImage: "arrow.clockwise", label: "もう一度生成") { runSelectedGeneration() }
                IconButton(systemImage: "arrow.up.forward.app", label: "生成物を開く", tone: .accent) {
                    generation.openResult(url)
                }
            }
        case let .failed(message):
            HStack(alignment: .top, spacing: 6) {
                Text(message)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                Spacer()
                IconButton(systemImage: "arrow.clockwise", label: "もう一度生成") { runSelectedGeneration() }
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
                    .foregroundStyle(.secondary)
            } else if state.pipelineRunning {
                ProgressView()
                    .controlSize(.mini)
                Text("パイプラインを実行中…（詳細は「生成」）")
                    .foregroundStyle(.secondary)
            } else if case let .failed(message) = state.generationState {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Text("処理に失敗: \(message)")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Spacer()
                IconButton(systemImage: "arrow.clockwise", label: "処理を再試行") {
                    generation.processNextUnprocessed()
                }
            } else {
                Image(systemName: "tray.full")
                    .foregroundStyle(.orange)
                Text("未処理の記録 \(state.stewardFindings.count) 件")
                    .foregroundStyle(.secondary)
                Spacer()
                IconButton(systemImage: "play.fill", label: "未処理の記録を処理", tone: .accent) {
                    generation.processNextUnprocessed()
                }
            }
        }
        .font(.caption)
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
        pipeline.refresh()
        if selectedPlaybookID.isEmpty || !state.pipelinePlaybooks.contains(where: { $0.id == selectedPlaybookID }) {
            selectedPlaybookID = state.pipelinePlaybooks.first?.id ?? ""
        }
        // 保存先の走査は MainActor から外れて非同期に終わるため、
        // セッション・テンプレートの選択合わせは読み込み完了後に行う
        Task {
            await generation.refresh()
            reconcileSelection(with: state.generationSessions)
            if selectedTemplateID.isEmpty || !state.generationTemplates.contains(where: { $0.id == selectedTemplateID }) {
                selectedTemplateID = state.generationTemplates.first?.id ?? ""
            }
            if let session = selectedSession {
                await pipeline.loadStates(for: session)
            }
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
