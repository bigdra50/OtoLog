import Foundation

// MARK: - StewardFinding

/// 未処理セッションの検出結果。
public struct StewardFinding: Sendable, Equatable {
    // MARK: Lifecycle

    public init(session: SessionRef, needsTitle: Bool, needsPipeline: Bool) {
        self.session = session
        self.needsTitle = needsTitle
        self.needsPipeline = needsPipeline
    }

    // MARK: Public

    public let session: SessionRef
    public let needsTitle: Bool
    public let needsPipeline: Bool
}

// MARK: - SessionSteward

/// 記録しっぱなしで後処理されていないセッションを見つける番人。
/// 完了済み（または開始から十分時間が経ったクラッシュ残骸）のうち、
/// タイトルかパイプラインが未処理のものを新しい順で返す。
public struct SessionSteward: Sendable {
    // MARK: Lifecycle

    public init(saveDirectory: URL, timeZone: TimeZone, staleThreshold: TimeInterval = 24 * 3600) {
        self.saveDirectory = saveDirectory
        self.timeZone = timeZone
        self.staleThreshold = staleThreshold
    }

    // MARK: Public

    /// openSessions は保存中の記録の相対パス（SessionWorkLock.openSessionNames）。
    /// 開いている記録は、どれだけ長く続いていても対象にしない。タイトル付与とパイプラインは開いている記録を断る
    public func findings(now: Date = Date(), excluding openSessions: Set<String> = []) -> [StewardFinding] {
        let reader = TranscriptReader(directory: saveDirectory, timeZone: timeZone)
        return reader.availableSessions().compactMap { session in
            guard !openSessions.contains(session.directoryName),
                  let meta = reader.meta(in: session) else { return nil }
            // endedAt が無い = 記録中の可能性。開始から十分古いものだけクラッシュ残骸として扱う
            let isSettled = meta.endedAt != nil
                || now.timeIntervalSince(meta.startedAt) >= staleThreshold
            guard isSettled else { return nil }

            // 記録が空のセッション（誤開始の残骸など）は処理しても必ず失敗するので対象外
            let transcript = saveDirectory
                .appendingPathComponent(session.directoryName)
                .appendingPathComponent("transcript.jsonl")
            let size = ((try? FileManager.default.attributesOfItem(atPath: transcript.path))?[.size] as? Int) ?? 0
            guard size > 0 else { return nil }

            let needsTitle = meta.title == nil
            let needsPipeline = meta.playbookID == nil
            guard needsTitle || needsPipeline else { return nil }
            return StewardFinding(session: session, needsTitle: needsTitle, needsPipeline: needsPipeline)
        }
    }

    // MARK: Private

    private let saveDirectory: URL
    private let timeZone: TimeZone
    private let staleThreshold: TimeInterval
}
