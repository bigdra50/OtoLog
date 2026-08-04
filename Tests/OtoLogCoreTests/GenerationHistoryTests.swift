import Foundation
@testable import OtoLogCore
import Testing

/// 生成物の世代退避。再生成は上書きなので、前の版と見比べたくなったときの戻り先を用意する。
struct GenerationHistoryTests {
    // MARK: Internal

    @Test func 対象が無ければ何もしない() throws {
        try withTempDir { dir in
            try GenerationHistory.archive(dir.appendingPathComponent("minutes.md"), now: base)

            #expect(!FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(GenerationHistory.directoryName).path
            ))
        }
    }

    @Test func 上書き前の版を退避する() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("minutes.md")
            try "前の版".write(to: url, atomically: true, encoding: .utf8)

            try GenerationHistory.archive(url, now: base)

            let versions = GenerationHistory.versions(of: "minutes.md", in: dir)
            #expect(versions.count == 1)
            #expect(try String(contentsOf: versions[0], encoding: .utf8) == "前の版")
            #expect(versions[0].lastPathComponent == "minutes-20260729T040000Z.md")
        }
    }

    /// 退避は複製。書き出しが失敗しても元の生成物が消えない
    @Test func 退避しても元のファイルは残る() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("minutes.md")
            try "前の版".write(to: url, atomically: true, encoding: .utf8)

            try GenerationHistory.archive(url, now: base)

            #expect(try String(contentsOf: url, encoding: .utf8) == "前の版")
        }
    }

    @Test func 新しい順に返す() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("minutes.md")
            for index in 0..<3 {
                try "版\(index)".write(to: url, atomically: true, encoding: .utf8)
                try GenerationHistory.archive(url, now: base.addingTimeInterval(Double(index) * 60))
            }

            let bodies = try GenerationHistory.versions(of: "minutes.md", in: dir)
                .map { try String(contentsOf: $0, encoding: .utf8) }
            #expect(bodies == ["版2", "版1", "版0"])
        }
    }

    /// 際限なく貯めない。見比べるのに足りる範囲で古いものから落とす
    @Test func 上限を超えたら古い世代から消す() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("minutes.md")
            let total = GenerationHistory.maxGenerations + 2
            for index in 0..<total {
                try "版\(index)".write(to: url, atomically: true, encoding: .utf8)
                try GenerationHistory.archive(url, now: base.addingTimeInterval(Double(index) * 60))
            }

            let bodies = try GenerationHistory.versions(of: "minutes.md", in: dir)
                .map { try String(contentsOf: $0, encoding: .utf8) }
            #expect(bodies.count == GenerationHistory.maxGenerations)
            #expect(bodies.first == "版\(total - 1)")
            #expect(bodies.last == "版\(total - GenerationHistory.maxGenerations)")
        }
    }

    /// 刈り込みはファイルごとに数える。議事録を作り直しても用語集の履歴は減らない
    @Test func 別の生成物の世代は巻き添えにしない() throws {
        try withTempDir { dir in
            let minutes = dir.appendingPathComponent("minutes.md")
            let glossary = dir.appendingPathComponent("glossary.md")
            try "用語集".write(to: glossary, atomically: true, encoding: .utf8)
            try GenerationHistory.archive(glossary, now: base)
            for index in 0..<(GenerationHistory.maxGenerations + 2) {
                try "議事録\(index)".write(to: minutes, atomically: true, encoding: .utf8)
                try GenerationHistory.archive(minutes, now: base.addingTimeInterval(Double(index + 1) * 60))
            }

            #expect(GenerationHistory.versions(of: "glossary.md", in: dir).count == 1)
        }
    }

    /// 構造化出力は JSON が正本。拡張子ごとに別枠で残す
    @Test func 拡張子ごとに別枠で数える() throws {
        try withTempDir { dir in
            let markdown = dir.appendingPathComponent("actions.md")
            let json = dir.appendingPathComponent("actions.json")
            try "本文".write(to: markdown, atomically: true, encoding: .utf8)
            try #"{"actions":[]}"#.write(to: json, atomically: true, encoding: .utf8)

            try GenerationHistory.archive(markdown, now: base)
            try GenerationHistory.archive(json, now: base)

            #expect(GenerationHistory.versions(of: "actions.md", in: dir).count == 1)
            #expect(GenerationHistory.versions(of: "actions.json", in: dir).count == 1)
        }
    }

    /// いつの版かは一覧に出すので、ファイル名から時刻を戻せる必要がある
    @Test func 退避した時刻を読み戻せる() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("minutes.md")
            try "前の版".write(to: url, atomically: true, encoding: .utf8)

            try GenerationHistory.archive(url, now: base)

            let version = try #require(GenerationHistory.versions(of: "minutes.md", in: dir).first)
            #expect(GenerationHistory.archivedAt(version) == base)
        }
    }

    @Test func 退避先でないファイルからは時刻を読まない() {
        #expect(GenerationHistory.archivedAt(URL(fileURLWithPath: "/tmp/minutes.md")) == nil)
        #expect(GenerationHistory.archivedAt(URL(fileURLWithPath: "/tmp/minutes-draft.md")) == nil)
    }

    // MARK: Private

    private let base = Date(timeIntervalSince1970: 1_785_297_600)

    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtoLogHistory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }
}
