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

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
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
        } detail: {
            if let row = rows.first(where: { $0.id == selectedID }) {
                SessionDetailView(settings: settings, session: row.session)
                    .id(row.id)
            } else {
                Text(rows.isEmpty ? "記録がまだありません" : "セッションを選択してください")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: reload)
    }

    // MARK: Private

    @State private var rows: [LibrarySessionRow] = []
    @State private var selectedID: String?

    /// 日付セクションでグルーピング（新しい日付が上）
    private var groupedRows: [(date: String, rows: [LibrarySessionRow])] {
        let namer = SessionDirectoryNamer(timeZone: .current)
        let grouped = Dictionary(grouping: rows) { namer.dateComponent(for: $0.session.startedAt) }
        return grouped.keys.sorted(by: >).map { (date: $0, rows: grouped[$0] ?? []) }
    }

    private func sidebarRow(_ row: LibrarySessionRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.session.displayName)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(subtitle(for: row))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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

    private func reload() {
        let reader = TranscriptReader(directory: settings.saveDirectory, timeZone: .current)
        rows = reader.availableSessions().map { session in
            LibrarySessionRow(session: session, meta: reader.meta(in: session))
        }
        if selectedID == nil || !rows.contains(where: { $0.id == selectedID }) {
            selectedID = rows.first?.id
        }
    }
}
