import OtoLogCore
import SwiftUI

// MARK: - GenerationActivityItem

/// アクティビティ一覧の1行分。
struct GenerationActivityItem: Identifiable {
    enum Status {
        case running
        case done(warnings: [String])
        case failed(message: String)
    }

    let id: String
    let sessionID: String
    let sessionName: String
    let taskName: String
    let status: Status
    let finishedAt: Date?
}

// MARK: - GenerationActivityView

/// 生成の進行と結果を1箇所で見せるアクティビティパネル
/// （UnityHub / JetBrains Toolbox のタスクパネルに相当）。
/// 実行中はコーディネータの状態を、完了分は各セッションの meta.json に永続化された
/// タスク状態を映す。生成物本文を開かなくても、警告付きで完了したことに気づけるようにする。
struct GenerationActivityView: View {
    // MARK: Internal

    let rows: [LibrarySessionRow]
    let generation: LibraryGenerationCoordinator
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("生成アクティビティ")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            if items.isEmpty {
                Text("生成の履歴はまだありません")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            row(item)
                            Divider().padding(.leading, 34)
                        }
                    }
                }
            }
        }
        .frame(width: 380, height: 400)
    }

    // MARK: Private

    /// 実行中（コーディネータ）→ 完了分（meta.json、新しい順）の順に並べる
    private var items: [GenerationActivityItem] {
        let templates = TemplateStore().loadTemplates()
        let playbooks = PlaybookStore().loadPlaybooks()
        let nameByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.session.displayName) })

        let running = generation.runningEntries.map { entry in
            GenerationActivityItem(
                id: "running/\(entry.id)",
                sessionID: entry.sessionID,
                sessionName: nameByID[entry.sessionID] ?? entry.sessionID,
                taskName: taskName(for: entry.label, templates: templates, playbooks: playbooks),
                status: .running,
                finishedAt: nil
            )
        }

        // 実行中のセッション×タスクは meta 側にも running/pending で載るため、コーディネータ側を正とする
        let runningKeys = Set(generation.runningEntries.map(\.id))
        var completed: [GenerationActivityItem] = []
        for row in rows {
            for (taskID, state) in row.meta?.pipeline ?? [:] {
                guard !runningKeys.contains("\(row.id)/\(taskID)") else { continue }
                let status: GenerationActivityItem.Status
                switch state.status {
                case .done:
                    status = .done(warnings: state.warnings ?? [])
                case .failed:
                    status = .failed(message: state.error ?? "失敗しました")
                case .pending, .running, .skipped:
                    continue
                }
                completed.append(GenerationActivityItem(
                    id: "\(row.id)/\(taskID)",
                    sessionID: row.id,
                    sessionName: row.session.displayName,
                    taskName: taskName(for: taskID, templates: templates, playbooks: playbooks),
                    status: status,
                    finishedAt: state.finishedAt
                ))
            }
        }
        completed.sort { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
        // 際限なく並べない。直近を見るパネルであって全履歴のビューではない
        return running + completed.prefix(30)
    }

    private func row(_ item: GenerationActivityItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(item.status)
                .frame(width: 24, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.taskName)
                    .font(.callout)
                Text(item.sessionName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                statusDetail(item.status)
            }
            Spacer(minLength: 8)
            if let finishedAt = item.finishedAt {
                Text(Self.finishedLabel(finishedAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(item.sessionID) }
        .help("クリックでこのセッションを開く")
    }

    @ViewBuilder private func statusIcon(_ status: GenerationActivityItem.Status) -> some View {
        switch status {
        case .running:
            ProgressView().controlSize(.small)
        case let .done(warnings) where warnings.isEmpty:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .done:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder private func statusDetail(_ status: GenerationActivityItem.Status) -> some View {
        switch status {
        case .running:
            Text("生成中…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .done(warnings) where !warnings.isEmpty:
            ForEach(warnings, id: \.self) { warning in
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        case .done:
            EmptyView()
        case let .failed(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private static func finishedLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }

    private func taskName(
        for label: String, templates: [GenerationTemplate], playbooks: [Playbook]
    ) -> String {
        if label.hasPrefix("playbook:") {
            let id = String(label.dropFirst("playbook:".count))
            let name = playbooks.first { $0.id == id }?.displayName ?? id
            return "\(name)（通し実行）"
        }
        return templates.first { $0.id == label }?.displayName ?? label
    }
}
