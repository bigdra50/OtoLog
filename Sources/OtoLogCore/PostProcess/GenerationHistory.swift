import Foundation

/// 生成物の世代退避。
///
/// 再生成は上書きなので、作り直してから「前のほうが良かった」と気づいても戻せない。
/// プロンプトや辞書に手を入れるたび出来は変わるため、直前の版と見比べられる状態を保つ。
/// 置き場はセッションディレクトリ直下の `.history`（生成物の一覧は拡張子で拾うので混ざらない）。
public enum GenerationHistory {
    // MARK: Public

    public static let directoryName = ".history"

    /// 保持する世代数。見比べるのに足りて、セッションディレクトリが膨らまない範囲
    public static let maxGenerations = 5

    /// これから上書きする生成物を退避する。対象が無ければ何もしない。
    /// 移動ではなく複製にするのは、続く書き出しが失敗しても元の生成物を失わないため
    public static func archive(_ fileURL: URL, now: Date) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        let directory = historyDirectory(in: fileURL.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stem = fileURL.deletingPathExtension().lastPathComponent
        let destination = directory
            .appendingPathComponent("\(stem)-\(timestamp(now))")
            .appendingPathExtension(fileURL.pathExtension)
        // 同じ秒に作り直したときは新しいほうを残す
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: fileURL, to: destination)

        for old in versions(stem: stem, extension: fileURL.pathExtension, in: directory)
            .dropFirst(maxGenerations) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    /// 退避済みの版を新しい順に返す。`fileName` は生成物のファイル名（例: "minutes.md"）
    public static func versions(of fileName: String, in sessionDirectory: URL) -> [URL] {
        let name = URL(fileURLWithPath: fileName)
        return versions(
            stem: name.deletingPathExtension().lastPathComponent,
            extension: name.pathExtension,
            in: historyDirectory(in: sessionDirectory)
        )
    }

    /// 退避した時刻。退避先の名前でなければ nil
    public static func archivedAt(_ url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let match = name.firstMatch(of: /-(\d{8}T\d{6}Z)$/) else { return nil }
        return formatter().date(from: String(match.1))
    }

    // MARK: Private

    private static func historyDirectory(in sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// 名前の時刻部分は固定長なので、辞書順の降順がそのまま新しい順になる
    private static func versions(stem: String, extension ext: String, in directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return urls
            .filter { $0.pathExtension == ext && isVersion($0, of: stem) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// 時刻部分の形まで見る。`minutes` の履歴に `minutes-draft` を数えないため
    private static func isVersion(_ url: URL, of stem: String) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("\(stem)-") else { return false }
        return name.dropFirst(stem.count + 1).wholeMatch(of: /\d{8}T\d{6}Z/) != nil
    }

    private static func timestamp(_ date: Date) -> String {
        formatter().string(from: date)
    }

    /// DateFormatter は Sendable でないため保持せず毎回生成する（PromptBuilder と同じ流儀）
    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        // ファイル名に使うのでコロンを避ける
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }
}
