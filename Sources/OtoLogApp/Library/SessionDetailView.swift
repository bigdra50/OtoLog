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

// MARK: - SessionDetailView

/// セッション詳細: ヘッダ + ドキュメント切替チップ + 本文（文字起こし or 生成物）。
struct SessionDetailView: View {
    // MARK: Internal

    let settings: AppSettings
    let session: SessionRef

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            documentChips
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            Divider()
            content
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    NSWorkspace.shared.open(sessionDirectory)
                } label: {
                    Label("Finder で開く", systemImage: "folder")
                }
                Button {
                    NSWorkspace.shared.open(currentFileURL)
                } label: {
                    Label("エディタで開く", systemImage: "square.and.pencil")
                }
            }
        }
        .onAppear(perform: reload)
    }

    // MARK: Private

    /// 文字起こしタブを表す予約 id（生成物のファイル名とは衝突しない）
    private static let transcriptTabID = "transcript"

    @State private var meta: SessionMeta?
    @State private var documents: [LibraryDocument] = []
    @State private var selectedTabID = SessionDetailView.transcriptTabID

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
        return sessionDirectory.appendingPathComponent(selectedTabID)
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

    @ViewBuilder private var content: some View {
        if selectedTabID == Self.transcriptTabID {
            TranscriptListView(settings: settings, session: session)
        } else {
            DocumentMarkdownView(url: sessionDirectory.appendingPathComponent(selectedTabID))
                .id(selectedTabID)
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

    private func reload() {
        let reader = TranscriptReader(directory: settings.saveDirectory, timeZone: .current)
        meta = reader.meta(in: session)

        let templates = TemplateStore().loadTemplates()
        let templateOrder = Dictionary(
            uniqueKeysWithValues: templates.enumerated().map { ($0.element.id, $0.offset) }
        )
        documents = reader.generatedDocumentFileNames(in: session)
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
    }
}
