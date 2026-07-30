import OtoLogCore
import SwiftUI

// MARK: - TranscriptContent

/// 文字起こしタブの読み込み結果（原文・補正・変更行差分）。
struct TranscriptContent: Equatable {
    var originalLines: [TimestampedLogParser.Line] = []
    var correctedLines: [TimestampedLogParser.Line]?
    var diffEntries: [TranscriptDiff.Entry] = []
}

// MARK: - TranscriptListView

/// 文字起こしビュー。補正結果（correct.md）があればそれを主役として表示し、
/// 「原文 / 差分」へ切り替えられる。差分は変更行だけを文字単位ハイライトで見せる
/// （補正が正しければ原文を見る機会はほぼなく、違和感のある箇所だけ確認する導線）。
struct TranscriptListView: View {
    // MARK: Internal

    let settings: AppSettings
    let session: SessionRef

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if correctedLines != nil {
                Picker("", selection: $mode) {
                    Text("補正後").tag(Mode.corrected)
                    Text("原文").tag(Mode.original)
                    Text("差分（\(diffEntries.count)）").tag(Mode.diff)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            ScrollView {
                content
            }
        }
        .task { await reload() }
    }

    /// 原文と補正（correct.md）を読み、突合用の正規化と差分抽出まで行う。
    /// 保存先を読むので MainActor では呼ばない
    nonisolated static func load(
        directory: URL, session: SessionRef, timeZone: TimeZone = .current
    ) -> TranscriptContent {
        let reader = TranscriptReader(directory: directory, timeZone: timeZone)
        let segments = (try? reader.segments(in: session)) ?? []
        var content = TranscriptContent()
        // 補正側（collapse 済み）と突合できるよう、原文も同じ正規化で1行化する
        content.originalLines = segments.map { segment in
            TimestampedLogParser.Line(
                time: timeText(segment.finalizedAt, timeZone: timeZone),
                text: segment.text.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            )
        }
        let correctURL = directory
            .appendingPathComponent(session.directoryName)
            .appendingPathComponent("correct.md")
        if let raw = try? String(contentsOf: correctURL, encoding: .utf8),
           let lines = TimestampedLogParser.parse(PostProcessRunner.stripProvenanceHeader(raw)) {
            content.correctedLines = lines
            content.diffEntries = TranscriptDiff.changedEntries(
                original: content.originalLines, corrected: lines
            )
        }
        return content
    }

    // MARK: Private

    private enum Mode {
        case corrected
        case original
        case diff
    }

    @State private var mode = Mode.original
    @State private var originalLines: [TimestampedLogParser.Line] = []
    @State private var correctedLines: [TimestampedLogParser.Line]?
    @State private var diffEntries: [TranscriptDiff.Entry] = []

    @ViewBuilder private var content: some View {
        switch mode {
        case .corrected:
            lineList(correctedLines ?? [])
        case .original:
            lineList(originalLines)
        case .diff:
            if diffEntries.isEmpty {
                Text("補正による変更はありません")
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(diffEntries.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(entry.time)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(diffText(entry.segments))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(16)
                .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func lineList(_ lines: [TimestampedLogParser.Line]) -> some View {
        if lines.isEmpty {
            Text("文字起こしがありません")
                .foregroundStyle(.secondary)
                .padding()
                .frame(maxWidth: .infinity)
        } else {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    TimestampedRow(time: line.time, text: line.text)
                }
            }
            .padding(16)
            .textSelection(.enabled)
        }
    }

    private nonisolated static func timeText(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func diffText(_ segments: [CharacterDiff.Segment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            var part = AttributedString(segment.text)
            switch segment.kind {
            case .equal:
                break
            case .removed:
                part.foregroundColor = .red
                part.strikethroughStyle = .single
            case .inserted:
                part.foregroundColor = .green
                part.underlineStyle = .single
            }
            result += part
        }
        return result
    }

    private func reload() async {
        let directory = settings.saveDirectory
        let session = session
        let loaded = await OffMainIO.read { Self.load(directory: directory, session: session) }
        originalLines = loaded.originalLines
        correctedLines = loaded.correctedLines
        diffEntries = loaded.diffEntries
        mode = loaded.correctedLines != nil ? .corrected : .original
    }
}
