import AppKit
import OtoLogCore
import SwiftUI

// MARK: - LibraryDocument

/// ドキュメントセレクタの1項目（生成物 md）。
struct LibraryDocument: Identifiable {
    let fileName: String
    let displayName: String

    var id: String {
        fileName
    }
}

// MARK: - DocumentVersion

/// 作り直す前に退避された生成物1件。
struct DocumentVersion: Identifiable {
    let url: URL
    /// その版が作られた時刻（由来コメント由来。読めなければ退避した時刻）
    let generatedAt: Date?

    var id: URL {
        url
    }
}

// MARK: - SessionDetailContent

/// セッション詳細の読み込み結果（meta + 生成物一覧）。
struct SessionDetailContent {
    let meta: SessionMeta?
    let documents: [LibraryDocument]
}

// MARK: - SessionDetailView

/// セッション詳細: ヘッダ + ドキュメント切替チップ + 本文（文字起こし or 生成物）。
struct SessionDetailView: View {
    // MARK: Internal

    let settings: AppSettings
    let session: SessionRef
    let generation: LibraryGenerationCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            documentChips
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            if let generationError = generation.error(for: session) {
                // ツールチップだけだと気づけないので本文側にも出す
                Label(generationError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            // 生成は完走してもツールが使えていないことがある（Web 検索なしの用語集など）。
            // 本文の但し書きを読まなくても分かるよう、警告として明示する
            ForEach(currentWarnings, id: \.self) { warning in
                Label("\(warning)（再生成で解消できる場合があります）", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            Divider()
            versionBar
            content
        }
        .toolbar {
            ToolbarItemGroup {
                regenerateControl
                copyPathButton
                openMenu
            }
        }
        .task { await reload() }
        .onChange(of: selectedTabID) { _, _ in
            // 版は生成物ごとに別。タブを移ったら最新に戻す
            selectedVersionURL = nil
            Task { await reloadVersions() }
        }
        .onChange(of: generation.finished?.session) { _, finished in
            guard finished == session.id else { return }
            Task {
                // 作り直した直後に古い版を映したままにしない
                selectedVersionURL = nil
                await reload()
                // 作り直したものをそのまま見せる
                if let templateID = generation.finished?.templateID,
                   documents.contains(where: { $0.fileName == "\(templateID).md" }) {
                    selectedTabID = "\(templateID).md"
                }
            }
        }
    }

    /// meta と生成物一覧（テンプレート定義順 → 名前順）を組み立てる。
    /// 保存先を読むので MainActor では呼ばない
    nonisolated static func load(
        directory: URL, session: SessionRef, timeZone: TimeZone = .current
    ) -> SessionDetailContent {
        let reader = TranscriptReader(directory: directory, timeZone: timeZone)
        let templates = TemplateStore().loadTemplates()
        let templateOrder = Dictionary(
            uniqueKeysWithValues: templates.enumerated().map { ($0.element.id, $0.offset) }
        )
        let documents = reader.generatedDocumentFileNames(in: session)
            .filter { $0 != "correct.md" } // 補正は文字起こしタブに統合（補正後/原文/差分の切替）
            .map { fileName in
                let templateID = String(fileName.dropLast(".md".count))
                return LibraryDocument(
                    fileName: fileName,
                    displayName: templates.first { $0.id == templateID }?.displayName ?? templateID
                )
            }
            .sorted { lhs, rhs in
                let lhsOrder = templateOrder[String(lhs.fileName.dropLast(3))] ?? Int.max
                let rhsOrder = templateOrder[String(rhs.fileName.dropLast(3))] ?? Int.max
                return lhsOrder != rhsOrder ? lhsOrder < rhsOrder : lhs.fileName < rhs.fileName
            }
        return SessionDetailContent(meta: reader.meta(in: session), documents: documents)
    }

    // MARK: Private

    /// 文字起こしタブを表す予約 id（生成物のファイル名とは衝突しない）
    private static let transcriptTabID = "transcript"

    @State private var meta: SessionMeta?
    @State private var documents: [LibraryDocument] = []
    @State private var selectedTabID = SessionDetailView.transcriptTabID
    /// 開いている生成物の、作り直す前の版（新しい順）
    @State private var versions: [DocumentVersion] = []
    /// 過去の版を表示中ならその URL。nil なら最新
    @State private var selectedVersionURL: URL?

    /// パスコピー直後の完了表示（チェックマーク）中かどうか
    @State private var pathCopied = false

    /// 開いているタブが指す生成物のテンプレート。文字起こしタブなら nil
    private var currentTemplate: GenerationTemplate? {
        guard selectedTabID != Self.transcriptTabID else { return nil }
        let templateID = String(selectedTabID.dropLast(".md".count))
        return TemplateStore().loadTemplates().first { $0.id == templateID }
    }

    /// 開いている生成物の実行時警告（ツールの権限拒否等）。
    /// 過去の版の表示中は、その版の実行と対応しない可能性があるため出さない
    private var currentWarnings: [String] {
        guard selectedTabID != Self.transcriptTabID, selectedVersionURL == nil else { return [] }
        let taskID = String(selectedTabID.dropLast(".md".count))
        return meta?.pipeline?[taskID]?.warnings ?? []
    }

    /// 開いているタブの表示名（メニュー項目で開く対象を名指しするために使う）
    private var currentDocumentName: String {
        currentTemplate?.displayName ?? "文字起こし"
    }

    private var sessionDirectory: URL {
        settings.saveDirectory.appendingPathComponent(session.directoryName)
    }

    private var currentFileURL: URL {
        if selectedTabID == Self.transcriptTabID {
            let markdown = sessionDirectory.appendingPathComponent("transcript.md")
            return FileManager.default.fileExists(atPath: markdown.path)
                ? markdown
                : sessionDirectory.appendingPathComponent("transcript.jsonl")
        }
        return displayedURL
    }

    /// 本文に出すファイル。過去の版を選んでいればそちら
    private var displayedURL: URL {
        selectedVersionURL ?? sessionDirectory.appendingPathComponent(selectedTabID)
    }

    private var currentVersionLabel: String {
        guard let selectedVersionURL else { return "最新" }
        return versions.first { $0.url == selectedVersionURL }.map(Self.versionLabel) ?? "作り直す前"
    }

    private var dateRangeText: String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd HH:mm"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"
        var text = day.string(from: session.startedAt)
        if let endedAt = meta?.endedAt {
            let minutes = max(1, Int(endedAt.timeIntervalSince(session.startedAt) / 60))
            text += " - \(time.string(from: endedAt))（\(minutes)分）"
        } else {
            text += " -（記録中または不明）"
        }
        return text
    }

    /// 生成の導線はこれ1つに畳む。
    /// 「再生成」「通しで再生成」「他を生成」を並べるとどれも同じに見えて選べない。
    /// 生成物タブではクリックで「いま開いているもの」を作り直し、それ以外はメニューへ落とす。
    /// 文字起こしタブは生成物ではないので、押しても何も起きないクリック面を作らずメニューだけにする
    @ViewBuilder private var regenerateControl: some View {
        if let template = currentTemplate {
            Menu {
                regenerateMenuItems
            } label: {
                regenerateLabel
            } primaryAction: {
                Task { await generation.generate(session: session, template: template) }
            }
            .labelStyle(.titleAndIcon)
            .disabled(generation.isRunning(session: session))
            .help("「\(template.displayName)」を補正済みのテキストから作り直す")
        } else {
            Menu {
                regenerateMenuItems
            } label: {
                regenerateLabel
            }
            .labelStyle(.titleAndIcon)
            .disabled(generation.isRunning(session: session))
            .help("生成するものを選ぶ")
        }
    }

    @ViewBuilder private var regenerateMenuItems: some View {
        if let template = currentTemplate {
            Section {
                Button("「\(template.displayName)」を作り直す") {
                    Task { await generation.generate(session: session, template: template) }
                }
            }
        }
        Section("ほかの生成物を作り直す") {
            ForEach(TemplateStore().loadTemplates()) { template in
                Button(template.displayName) {
                    Task { await generation.generate(session: session, template: template) }
                }
            }
        }
        Section("音声認識の補正からやり直す") {
            ForEach(PlaybookStore().loadPlaybooks()) { playbook in
                Button(playbook.displayName) {
                    Task { await generation.generate(session: session, playbook: playbook) }
                }
            }
        }
    }

    /// ツールバーは既定でアイコンだけになるが、生成は重い操作なので文字も常時出す。
    /// 「更新」ボタンと同じ回転矢印だと見分けが付かないため、AI 生成の慣習である sparkles を使う
    @ViewBuilder private var regenerateLabel: some View {
        if let runningID = generation.runningTemplateID(for: session) {
            Label {
                Text(runningLabel(runningID))
            } icon: {
                ProgressView().controlSize(.small)
            }
        } else {
            Label(currentTemplate == nil ? "生成" : "再生成", systemImage: "sparkles")
        }
    }

    /// 開いているファイルのパスを1クリックでコピーする。
    /// 記録を Claude Code 等の外部ツールへ渡すときにパス文字列を貼るのが主用途。
    /// 過去の版を表示中はその版のパスをコピーする（見えているものと一致させる）
    private var copyPathButton: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(currentFileURL.path, forType: .string)
            pathCopied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                pathCopied = false
            }
        } label: {
            Label("パスをコピー", systemImage: pathCopied ? "checkmark" : "doc.on.doc")
        }
        .help("「\(currentDocumentName)」のファイルパスをコピー")
    }

    /// Finder とエディタの導線。アイコン2個を並べると意味が読めないのでメニュー1つに畳む
    private var openMenu: some View {
        Menu {
            Button("「\(currentDocumentName)」をエディタで開く") {
                NSWorkspace.shared.open(currentFileURL)
            }
            Divider()
            Button("Finder でフォルダを表示") {
                NSWorkspace.shared.open(sessionDirectory)
            }
        } label: {
            Label("開く", systemImage: "folder")
        }
        .help("開いているファイルやセッションのフォルダを外部アプリで開く")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.displayName)
                .font(.title2)
                .bold()
                .lineLimit(1)
                .truncationMode(.tail)
            Text(dateRangeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var documentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(id: Self.transcriptTabID, label: "文字起こし")
                ForEach(documents) { document in
                    chip(id: document.id, label: document.displayName)
                }
            }
        }
    }

    /// 作り直す前の版への入口。
    /// 生成のたびに出来は変わるので、見比べられないと「前のほうが良かった」に対処できない。
    /// 履歴が無ければ何も出さない（初回生成しかしていないセッションで場所を取らない）
    @ViewBuilder private var versionBar: some View {
        if selectedTabID != Self.transcriptTabID, !versions.isEmpty {
            HStack(spacing: 8) {
                Menu {
                    Button("最新") { selectedVersionURL = nil }
                    Section("作り直す前") {
                        ForEach(versions) { version in
                            Button(Self.versionLabel(version)) { selectedVersionURL = version.url }
                        }
                    }
                } label: {
                    Label(currentVersionLabel, systemImage: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if selectedVersionURL != nil {
                    Text("作り直す前の内容を表示しています")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(selectedVersionURL == nil ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary.opacity(0.4)))
        }
    }

    @ViewBuilder private var content: some View {
        if selectedTabID == Self.transcriptTabID {
            TranscriptListView(settings: settings, session: session)
        } else {
            DocumentMarkdownView(url: displayedURL)
                .id(displayedURL)
        }
    }

    private func chip(id: String, label: String) -> some View {
        Button {
            selectedTabID = id
        } label: {
            Text(label)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    selectedTabID == id ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private static func versionLabel(_ version: DocumentVersion) -> String {
        guard let date = version.generatedAt else { return version.url.lastPathComponent }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date) + " に生成"
    }

    /// 通しの実行は playbook: 接頭辞で入っている
    private func runningLabel(_ runningID: String) -> String {
        guard runningID.hasPrefix("playbook:"),
              let playbookID = runningID.split(separator: ":", maxSplits: 1).last.map(String.init)
        else {
            let name = TemplateStore().loadTemplates()
                .first { $0.id == runningID }?.displayName ?? runningID
            return "\(name) を生成中…"
        }
        let name = PlaybookStore().loadPlaybooks().first { $0.id == playbookID }?.displayName ?? playbookID
        return "\(name) を通しで実行中…"
    }

    private func reload() async {
        let directory = settings.saveDirectory
        let session = session
        let loaded = await OffMainIO.read { Self.load(directory: directory, session: session) }
        meta = loaded.meta
        documents = loaded.documents
        await reloadVersions()
    }

    private func reloadVersions() async {
        guard selectedTabID != Self.transcriptTabID else {
            versions = []
            return
        }
        let directory = sessionDirectory
        let fileName = selectedTabID
        versions = await OffMainIO.read {
            GenerationHistory.versions(of: fileName, in: directory).map { url in
                // 退避名の時刻は「いつ置き換えたか」。いつ作られた版かは中の由来コメントが持つ
                let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                return DocumentVersion(
                    url: url,
                    generatedAt: PostProcessRunner.provenanceGeneratedAt(contents)
                        ?? GenerationHistory.archivedAt(url)
                )
            }
        }
    }
}
