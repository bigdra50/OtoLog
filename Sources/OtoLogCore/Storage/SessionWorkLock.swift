import Foundation

// MARK: - SessionWork

/// 記録ディレクトリへの作業の種類。
public enum SessionWork: Sendable, Equatable {
    /// タイトルを付けてディレクトリを移す（TitleAssigner）
    case retitle
    /// プレイブックを走らせ、meta.json に状態を書く（PipelineRunner）
    case pipeline
    /// 生成物を1つ書く（PostProcessRunner）
    case generation
}

// MARK: - SessionWorkLock

/// 記録ディレクトリごとの作業の受け持ち。
///
/// 1つの記録には、保存（SessionFileStore）、タイトル付与、パイプライン、単発生成が別々の経路から手を出す。
/// 重ねてよい組み合わせだけを通し、重ねられないものは待たせるか断る。
///
/// - 保存が開いている記録には、タイトル付与とパイプラインを断る。移すと保存が元の名前でディレクトリを作り直して記録が2つに割れ、
///   パイプラインの状態は閉じるときの meta.json の書き直しとぶつかる。記録は何時間も続くので、待たせずに断る
/// - タイトル付与は、同じ記録のほかの作業と重ねない。移した後は、待っていた作業と古い参照から来た作業を移った先へ向ける
/// - パイプラインどうしは重ねない。どちらも meta.json を読み直して自分の状態だけを書くため、後から書いた側が先の状態を消す
///
/// 待つ順番は到着順にする。待っているタイトル付与より後に来た生成を先に通すと、生成が続く間タイトル付与が進まない
public actor SessionWorkLock {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    /// 受け持ちの証。作業を終えたら release で返す
    public struct Lease: Sendable {
        // MARK: Public

        /// 受け持った記録。待つ間にタイトル付与で移っていれば、移った先
        public let session: SessionRef

        // MARK: Fileprivate

        fileprivate let id: UUID
        fileprivate let key: Key
    }

    /// アプリ内の保存・生成・パイプラインが共有する受け持ち。
    /// 別のプロセス（otolog-devtool）とは共有できないが、記録するのはアプリだけ
    public static let shared = SessionWorkLock()

    /// 保存が記録を開いた。返した受け持ちを release するまで、この記録へのタイトル付与とパイプラインを断る
    public func open(_ session: SessionRef, in root: URL) -> Lease {
        let key = Key(root: root, session: session)
        // 開くのは新しいディレクトリだけ。同じ名前の前の記録が移った跡は、この記録への参照を曲げないよう消す
        moves[key] = nil
        return grant(.recording, session: session, key: key)
    }

    /// 作業を受け持つ。重ねられない作業が同じ記録にあれば、終わるのを待つ。
    /// 開いている記録へのタイトル付与とパイプラインは sessionIsOpen で断る。待っている間に取り消されたら CancellationError
    public func acquire(_ work: SessionWork, for session: SessionRef, in root: URL) async throws -> Lease {
        let session = latestPlace(of: session, in: root)
        let key = Key(root: root, session: session)
        if Self.isRefused(work, holders: holders[key] ?? []) {
            throw SessionWorkLockError.sessionIsOpen
        }
        if queues[key, default: []].isEmpty, canGrant(work, key: key) {
            return grant(.work(work), session: session, key: key)
        }
        let id = UUID()
        let lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queues[key, default: []].append(
                    Waiter(id: id, work: work, session: session, continuation: continuation)
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        // 受け持つのと取り消しが入れ違ったときは、使わない受け持ちを返してから抜ける
        if Task.isCancelled {
            release(lease)
            throw CancellationError()
        }
        return lease
    }

    /// 受け持ちを返す。タイトル付与で記録を移したときは移った先を渡し、待っている作業をそちらへ向ける
    public func release(_ lease: Lease, movedTo destination: SessionRef? = nil) {
        holders[lease.key]?.removeAll { $0.id == lease.id }
        if holders[lease.key]?.isEmpty == true {
            holders[lease.key] = nil
        }
        guard let destination, destination.directoryName != lease.session.directoryName else {
            admit(lease.key)
            return
        }
        let newKey = Key(rootPath: lease.key.rootPath, name: destination.directoryName)
        moves[lease.key] = destination
        // 移った先は跡ではなく今の居場所。前に同じ名前から移った跡が残っていても、たどらない
        moves[newKey] = nil
        let followers = (queues.removeValue(forKey: lease.key) ?? []).map { waiter in
            var moved = waiter
            moved.session = destination
            return moved
        }
        queues[newKey, default: []].append(contentsOf: followers)
        admit(newKey)
    }

    /// 保存が開いている記録か
    public func isOpen(_ session: SessionRef, in root: URL) -> Bool {
        holders[Key(root: root, session: session)]?.contains { $0.kind == .recording } == true
    }

    /// 保存ルートの下で開いている記録の相対パス
    public func openSessionNames(in root: URL) -> Set<String> {
        let rootPath = Key.normalizedPath(of: root)
        return Set(holders.compactMap { key, list in
            key.rootPath == rootPath && list.contains { $0.kind == .recording } ? key.name : nil
        })
    }

    // MARK: Internal

    /// 待っている作業の数（テストで待ちに入ったことを確かめる）
    func waitingCount(for session: SessionRef, in root: URL) -> Int {
        queues[Key(root: root, session: latestPlace(of: session, in: root))]?.count ?? 0
    }

    // MARK: Fileprivate

    /// 保存ルートと相対パスの組。ルートはシンボリックリンクを解いて比べる（一時フォルダの /var と /private/var など）
    fileprivate struct Key: Hashable {
        // MARK: Lifecycle

        init(root: URL, session: SessionRef) {
            self.init(rootPath: Self.normalizedPath(of: root), name: session.directoryName)
        }

        init(rootPath: String, name: String) {
            self.rootPath = rootPath
            self.name = name
        }

        // MARK: Internal

        let rootPath: String
        let name: String

        static func normalizedPath(of root: URL) -> String {
            root.resolvingSymlinksInPath().standardizedFileURL.path
        }
    }

    // MARK: Private

    private enum Kind: Equatable {
        case recording
        case work(SessionWork)
    }

    private struct Holder {
        let id: UUID
        let kind: Kind
    }

    private struct Waiter {
        let id: UUID
        let work: SessionWork
        var session: SessionRef
        let continuation: CheckedContinuation<Lease, any Error>
    }

    private var holders: [Key: [Holder]] = [:]
    private var queues: [Key: [Waiter]] = [:]
    /// タイトル付与で移った記録の移り先。古い参照から来た作業を、移った先へ向ける
    private var moves: [Key: SessionRef] = [:]

    private static func isRefused(_ work: SessionWork, holders: [Holder]) -> Bool {
        work != .generation && holders.contains { $0.kind == .recording }
    }

    private static func conflicts(_ work: SessionWork, with held: Kind) -> Bool {
        switch (work, held) {
        case (.retitle, _), (_, .work(.retitle)), (.pipeline, .work(.pipeline)): true
        default: false
        }
    }

    private func canGrant(_ work: SessionWork, key: Key) -> Bool {
        !(holders[key] ?? []).contains { Self.conflicts(work, with: $0.kind) }
    }

    private func grant(_ kind: Kind, session: SessionRef, key: Key) -> Lease {
        let id = UUID()
        holders[key, default: []].append(Holder(id: id, kind: kind))
        return Lease(session: session, id: id, key: key)
    }

    /// 移り先をたどる。同じ名前で後から始まった別の記録は、開始時刻が違うのでたどらない
    private func latestPlace(of session: SessionRef, in root: URL) -> SessionRef {
        var current = session
        let rootPath = Key.normalizedPath(of: root)
        while let moved = moves[Key(rootPath: rootPath, name: current.directoryName)],
              moved.startedAt == current.startedAt {
            current = moved
        }
        return current
    }

    /// 並びの先頭から、受け持てるものを順に通す。先頭が通れなければ、後ろは待たせたままにする
    private func admit(_ key: Key) {
        while let next = queues[key]?.first {
            if Self.isRefused(next.work, holders: holders[key] ?? []) {
                queues[key]?.removeFirst()
                next.continuation.resume(throwing: SessionWorkLockError.sessionIsOpen)
                continue
            }
            guard canGrant(next.work, key: key) else { break }
            queues[key]?.removeFirst()
            next.continuation.resume(returning: grant(.work(next.work), session: next.session, key: key))
        }
        if queues[key]?.isEmpty == true {
            queues[key] = nil
        }
    }

    private func cancelWaiter(_ id: UUID) {
        for (key, waiters) in queues {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { continue }
            let waiter = waiters[index]
            queues[key]?.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
            // 取り消した作業が先頭で後ろを止めていたかもしれない
            admit(key)
            return
        }
    }
}

// MARK: - SessionWorkLockError

public enum SessionWorkLockError: Error, Equatable, LocalizedError {
    case sessionIsOpen

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case .sessionIsOpen:
            "記録中のセッションには実行できません。記録を止めてから実行してください。"
        }
    }
}
