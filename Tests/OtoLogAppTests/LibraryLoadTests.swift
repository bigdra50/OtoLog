import Foundation
@testable import OtoLogApp
import OtoLogCore
import Testing

// MARK: - LibraryRowsLoadTests

/// ライブラリ一覧の読み込み（セッション列挙 + meta 付与）を検証する。
struct LibraryRowsLoadTests {
    @Test func セッションを新しい順にmeta付きで返す() throws {
        try SessionFixture.withTempDir { root in
            try SessionFixture.make(in: root, name: "2026-07-28/0900", texts: ["古い"])
            try SessionFixture.make(in: root, name: "2026-07-29/1300", texts: ["新しい"])
            let rows = LibraryView.loadRows(directory: root, timeZone: SessionFixture.jst)
            #expect(rows.map(\.session.directoryName) == ["2026-07-29/1300", "2026-07-28/0900"])
            // meta が読めていれば一覧の時間長表示に使う endedAt がある
            #expect(rows.allSatisfy { $0.meta?.endedAt != nil })
        }
    }
}

// MARK: - SessionDetailLoadTests

/// セッション詳細の読み込み（meta + 生成物一覧の組み立て）を検証する。
struct SessionDetailLoadTests {
    @Test func 生成物一覧はcorrectを除き名前順で返す() throws {
        try SessionFixture.withTempDir { root in
            let ref = try SessionFixture.make(
                in: root, name: "2026-07-29/1300", texts: ["本文"], title: "講演メモ",
                documents: [
                    "correct.md": "[13:00:00] 補正",
                    "zzz-b.md": "生成物B",
                    "zzz-a.md": "生成物A",
                ]
            )
            let content = SessionDetailView.load(
                directory: root, session: ref, timeZone: SessionFixture.jst
            )
            // correct.md は文字起こしタブへ統合されるため一覧に出さない。
            // テンプレート定義に無い id は名前順
            #expect(content.documents.map(\.fileName) == ["zzz-a.md", "zzz-b.md"])
            #expect(content.documents.map(\.displayName) == ["zzz-a", "zzz-b"])
            #expect(content.meta?.title == "講演メモ")
        }
    }
}

// MARK: - DocumentMarkdownLoadTests

/// 生成物 md の読み込み(由来ヘッダ除去 + 行ログ判定)を検証する。
struct DocumentMarkdownLoadTests {
    @Test func 行ログは由来ヘッダを除いて時刻付き行になる() throws {
        try SessionFixture.withTempDir { root in
            let url = root.appendingPathComponent("correct.md")
            try """
            <!-- otolog:generated template=correct source=transcript.jsonl -->
            [13:00:00] 一行目
            [13:00:05] 二行目
            """.write(to: url, atomically: true, encoding: .utf8)
            let content = DocumentMarkdownView.load(url: url)
            #expect(content.timestampedLines?.map(\.text) == ["一行目", "二行目"])
            #expect(!content.content.contains("otolog:generated"))
        }
    }

    @Test func 通常のMarkdownは行ログ扱いにしない() throws {
        try SessionFixture.withTempDir { root in
            let url = root.appendingPathComponent("summary.md")
            try "# 要約\n\n本文".write(to: url, atomically: true, encoding: .utf8)
            let content = DocumentMarkdownView.load(url: url)
            #expect(content.timestampedLines == nil)
            #expect(content.content == "# 要約\n\n本文")
        }
    }

    @Test func 読めないファイルはエラーメッセージを返す() throws {
        try SessionFixture.withTempDir { root in
            let url = root.appendingPathComponent("missing.md")
            let content = DocumentMarkdownView.load(url: url)
            #expect(content.timestampedLines == nil)
            #expect(content.content.contains("missing.md"))
        }
    }
}
