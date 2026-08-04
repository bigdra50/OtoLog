import AppKit
import OtoLogCore
import SwiftUI

/// 前提知識の提案と確定。
///
/// 用語集の生成物から候補を集め、人が説明を直して確定させる。
/// AI の書いた説明は外れることがある（会議の文脈から自社アプリを案件名と読み違えた例がある）ので、
/// そのまま採らず必ず人の目を通す。
struct KnowledgeView: View {
    // MARK: Internal

    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !suggestions.isEmpty {
                        sectionTitle("提案 \(suggestions.count) 件", note: "用語集から集めた候補。説明を直して保存する")
                        ForEach(suggestions) { suggestion in
                            suggestionRow(suggestion)
                            Divider()
                        }
                    }
                    sectionTitle("確定済み \(entries.count) 件", note: "knowledge.md の内容。生成のたびにプロンプトへ入る")
                    if entries.isEmpty {
                        Text("まだありません。提案を保存すると貯まります。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                    ForEach(entries) { entry in
                        entryRow(entry)
                        Divider()
                    }
                }
            }
        }
        .task { await reload() }
    }

    // MARK: Private

    @State private var suggestions: [KnowledgeSuggestion] = []
    @State private var entries: [KnowledgeEntry] = []
    @State private var drafts: [String: String] = [:]

    private var header: some View {
        HStack {
            Text("前提知識")
                .font(.headline)
            Spacer()
            Button {
                Task { await collect() }
            } label: {
                Label("候補を集める", systemImage: "sparkle.magnifyingglass")
            }
            Button {
                NSWorkspace.shared.open(KnowledgeStore.defaultFileURL)
            } label: {
                Label("knowledge.md を開く", systemImage: "square.and.pencil")
            }
            Button {
                NSWorkspace.shared.open(SituationStore.defaultFileURL)
            } label: {
                Label("現況メモを開く", systemImage: "note.text")
            }
            .disabled(!FileManager.default.fileExists(atPath: SituationStore.defaultFileURL.path))
            .help("記録から育てた現況メモ（context.md）")
        }
        .padding(12)
    }

    private func sectionTitle(_ title: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline).fontWeight(.medium)
            Text(note).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.2))
    }

    private func suggestionRow(_ suggestion: KnowledgeSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(suggestion.term).fontWeight(.medium)
                Spacer()
                Text(suggestion.origin).font(.caption2).foregroundStyle(.secondary)
            }
            TextEditor(text: draftBinding(suggestion))
                .font(.caption)
                .frame(minHeight: 60, maxHeight: 120)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
            HStack(spacing: 4) {
                Spacer()
                decisionButton("xmark.circle.fill", tint: .red, help: "却下") {
                    Task { await dismiss(suggestion) }
                }
                decisionButton("checkmark.circle.fill", tint: .green, help: "保存") {
                    Task { await accept(suggestion) }
                }
            }
        }
        .padding(12)
    }

    private func entryRow(_ entry: KnowledgeEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.term).fontWeight(.medium)
            Text(entry.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 採否は一目で分かるほうがよいので、色つきのアイコンで出す
    private func decisionButton(
        _ systemImage: String,
        tint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func draftBinding(_ suggestion: KnowledgeSuggestion) -> Binding<String> {
        Binding {
            drafts[suggestion.term] ?? suggestion.body
        } set: { drafts[suggestion.term] = $0 }
    }

    private func accept(_ suggestion: KnowledgeSuggestion) async {
        let entry = KnowledgeEntry(
            term: suggestion.term,
            body: (drafts[suggestion.term] ?? suggestion.body)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        await OffMainIO.read {
            try? KnowledgeSuggestionStore().accept(entry, into: KnowledgeStore())
        }
        drafts[suggestion.term] = nil
        await reload()
    }

    private func dismiss(_ suggestion: KnowledgeSuggestion) async {
        let term = suggestion.term
        await OffMainIO.read { try? KnowledgeSuggestionStore().dismiss(term: term) }
        await reload()
    }

    /// 用語集を走査して候補を足す。確定済み・却下済みは除かれる
    private func collect() async {
        let directory = settings.saveDirectory
        await OffMainIO.read {
            let store = KnowledgeSuggestionStore()
            let existing = store.load()
            let dismissed = existing.filter { $0.state == .dismissed }.map(\.term)
            let found = KnowledgeCollector.collect(
                directory: directory,
                knowledge: KnowledgeStore().load(),
                dismissed: dismissed,
                now: Date()
            )
            let known = Set(existing.map(\.term))
            try? store.save(existing + found.filter { !known.contains($0.term) })
        }
        await reload()
    }

    private func reload() async {
        let loaded = await OffMainIO.read {
            (
                suggestions: KnowledgeSuggestionStore().load().filter { $0.state == .pending },
                entries: KnowledgeStore().load()
            )
        }
        suggestions = loaded.suggestions
        entries = loaded.entries
    }
}
