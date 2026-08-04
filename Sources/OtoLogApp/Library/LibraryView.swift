import AppKit
import OtoLogCore
import SwiftUI

// MARK: - LibrarySessionRow

/// サイドバー1行分の表示データ（meta は一覧表示の時間長に使う）。
struct LibrarySessionRow: Identifiable {
    let session: SessionRef
    let meta: SessionMeta?

    var id: String {
        session.id
    }
}

// MARK: - LibraryView

/// ライブラリのルート: セッション一覧（サイドバー）+ セッション詳細。
struct LibraryView: View {
    // MARK: Internal

    let settings: AppSettings
    let generation: LibraryGenerationCoordinator

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                Label("前提知識", systemImage: "character.book.closed")
                    .tag(Self.knowledgeID)
                ForEach(groupedRows, id: \.date) { group in
                    Section(group.date) {
                        ForEach(group.rows) { row in
                            sidebarRow(row)
                                .tag(row.id)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 250)
            // ゴミ箱移動は Finder から戻せるが、ホバー上のアイコン誤クリックで
            // 行が黙って消えると気づけないため一段確認を挟む
            .confirmationDialog(
                "セッションをゴミ箱に入れますか？",
                isPresented: Binding(
                    get: { rowPendingTrash != nil },
                    set: { if !$0 { rowPendingTrash = nil } }
                ),
                titleVisibility: .visible,
                presenting: rowPendingTrash
            ) { row in
                Button("「\(row.session.displayName)」をゴミ箱に入れる", role: .destructive) {
                    Task { await trash(row) }
                }
            } message: { _ in
                Text("文字起こしと生成物をフォルダごとゴミ箱へ移します。Finder のゴミ箱から戻せます。")
            }
            .alert(
                "ゴミ箱に入れられませんでした",
                isPresented: Binding(
                    get: { trashErrorMessage != nil },
                    set: { if !$0 { trashErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(trashErrorMessage ?? "")
            }
            // タイトル生成のリネームや新しい記録を、ウィンドウを開いたまま反映する。
            // 一覧の操作なので、詳細側の生成ボタンと混ざらないようサイドバー領域に置く
            .toolbar {
                ToolbarItem {
                    Button {
                        isActivityPresented.toggle()
                    } label: {
                        // UnityHub / JetBrains Toolbox のタスクボタンに倣い、
                        // 実行中はボタン自体をスピナーにして「何か走っている」ことを常時見せる
                        if generation.runningCount > 0 {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("生成アクティビティ", systemImage: "checklist")
                        }
                    }
                    .help("生成の進捗と結果を表示")
                    .popover(isPresented: $isActivityPresented, arrowEdge: .bottom) {
                        GenerationActivityView(rows: rows, generation: generation) { sessionID in
                            selectedID = sessionID
                            isActivityPresented = false
                        }
                    }
                }
                ToolbarItem {
                    Button {
                        Task { await reload() }
                    } label: {
                        Label("一覧を更新", systemImage: "arrow.clockwise")
                    }
                    .help("セッション一覧を読み直す")
                }
            }
            // 完了ステータスは meta.json 由来なので、パネルを開いた瞬間に読み直して最新にする
            .onChange(of: isActivityPresented) { _, presented in
                guard presented else { return }
                Task { await reload() }
            }
        } detail: {
            if selectedID == Self.knowledgeID {
                KnowledgeView(settings: settings)
            } else if let row = rows.first(where: { $0.id == selectedID }) {
                SessionDetailView(settings: settings, session: row.session, generation: generation)
                    .id(row.id)
            } else {
                Text(rows.isEmpty ? "記録がまだありません" : "セッションを選択してください")
                    .foregroundStyle(.secondary)
            }
        }
        .task { await reload() }
    }

    /// セッション列挙 + meta 付与。保存先を読むので MainActor では呼ばない
    nonisolated static func loadRows(directory: URL, timeZone: TimeZone = .current) -> [LibrarySessionRow] {
        let reader = TranscriptReader(directory: directory, timeZone: timeZone)
        return reader.availableSessions().map { session in
            LibrarySessionRow(session: session, meta: reader.meta(in: session))
        }
    }

    // MARK: Private

    /// セッション ID（保存先の相対パス）と衝突しない予約値
    private static let knowledgeID = "\u{1F}knowledge"

    @State private var rows: [LibrarySessionRow] = []

    @State private var selectedID: String?

    /// マウスが乗っている行。削除アイコンをその行だけに出す
    @State private var hoveredRowID: String?

    @State private var isActivityPresented = false

    /// 削除確認ダイアログ表示中の対象。nil なら非表示
    @State private var rowPendingTrash: LibrarySessionRow?

    @State private var trashErrorMessage: String?

    /// 日付セクションでグルーピング（新しい日付が上）
    private var groupedRows: [(date: String, rows: [LibrarySessionRow])] {
        let namer = SessionDirectoryNamer(timeZone: .current)
        let grouped = Dictionary(grouping: rows) { namer.dateComponent(for: $0.session.startedAt) }
        return grouped.keys.sorted(by: >).map { (date: $0, rows: grouped[$0] ?? []) }
    }

    private func sidebarRow(_ row: LibrarySessionRow) -> some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.session.displayName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // 別のセッションを眺めている間も進行が見えるようにする
                    if generation.isRunning(session: row.session) {
                        ProgressView().controlSize(.mini)
                    }
                }
                Text(subtitle(for: row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // 常時出すと一覧が削除ボタンだらけになるのでホバー行だけに出す
            if hoveredRowID == row.id {
                Button {
                    rowPendingTrash = row
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(generation.isRunning(session: row.session))
                .help(generation.isRunning(session: row.session) ? "生成中は削除できません" : "ゴミ箱に入れる")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredRowID = row.id
            } else if hoveredRowID == row.id {
                hoveredRowID = nil
            }
        }
        .contextMenu {
            Button("パスをコピー") { copyPath(of: row) }
            Button("Finder で表示") {
                NSWorkspace.shared.activateFileViewerSelecting([sessionDirectory(of: row)])
            }
            Divider()
            Button("ゴミ箱に入れる", role: .destructive) { rowPendingTrash = row }
                .disabled(generation.isRunning(session: row.session))
        }
    }

    private func sessionDirectory(of row: LibrarySessionRow) -> URL {
        settings.saveDirectory.appendingPathComponent(row.session.directoryName)
    }

    private func copyPath(of row: LibrarySessionRow) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sessionDirectory(of: row).path, forType: .string)
    }

    private func trash(_ row: LibrarySessionRow) async {
        let directory = settings.saveDirectory
        let relativePath = row.session.directoryName
        let result = await OffMainIO.read {
            Result { try SessionTrash.moveToTrash(root: directory, relativePath: relativePath) }
        }
        switch result {
        case .success:
            await reload()
        case let .failure(error):
            trashErrorMessage = error.localizedDescription
        }
    }

    private func subtitle(for row: LibrarySessionRow) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        var text = formatter.string(from: row.session.startedAt)
        if let endedAt = row.meta?.endedAt {
            let minutes = max(1, Int(endedAt.timeIntervalSince(row.session.startedAt) / 60))
            text += "・\(minutes)分"
        }
        return text
    }

    private func reload() async {
        let directory = settings.saveDirectory
        rows = await OffMainIO.read { Self.loadRows(directory: directory) }
        // 前提知識を開いている間の更新で、選択がセッション側へ飛ばないようにする
        guard selectedID != Self.knowledgeID else { return }
        if selectedID == nil || !rows.contains(where: { $0.id == selectedID }) {
            selectedID = rows.first?.id
        }
    }
}
