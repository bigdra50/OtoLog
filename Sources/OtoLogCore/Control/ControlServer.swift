import Foundation
import Network

/// Unix ドメインソケットで ControlRequest を受け付けるサーバー（アプリ内に常駐）。
/// プロトコルは1接続1リクエスト: 改行終端の JSON 1行を受け、JSON 1行を返して切断する。
/// ソケットは 0600 で自ユーザーのみ接続可能。localhost TCP と違いポート衝突・他ユーザー露出がない。
public final class ControlServer: @unchecked Sendable {
    // MARK: Lifecycle

    public init(socketPath: String, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    // MARK: Public

    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    public func start() throws {
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 前回の異常終了で残ったソケットファイルは bind を妨げるため先に消す
        try? FileManager.default.removeItem(atPath: socketPath)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        // bind は start 後に非同期で行われるため、ソケットファイルができた .ready 時点で権限を絞り、同一性を控える
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.claimSocketFile()
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        // 再起動では新しいインスタンスが同じパスへ bind し直した後にこちらが止まる。
        // パスだけで消すと新しい方のソケットを消してしまうため、自分が bind したファイルのときだけ消す。
        // bind を確認する前に止まった場合は残す（残骸なら次の start が消す）
        let boundSocket = lock.withLock {
            let bound = self.boundSocket
            self.boundSocket = nil
            return bound
        }
        if let boundSocket, FileIdentity(path: socketPath) == boundSocket {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    // MARK: Private

    /// デバイス番号と inode 番号の組。同じパスに作り直されたファイルを別物として見分ける
    private struct FileIdentity: Equatable {
        // MARK: Lifecycle

        init?(path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
        }

        // MARK: Internal

        let device: dev_t
        let inode: ino_t
    }

    /// 制御コマンドは小さい JSON のみ。これを超える入力は不正として切断する
    private static let maxRequestBytes = 64 * 1024

    private let socketPath: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.bigdra50.OtoLog.ControlServer")
    private var listener: NWListener?
    /// .ready（サーバーキュー）と stop（メインスレッド）の競合から boundSocket を守る
    private let lock = NSLock()
    /// .ready で控えた自分のソケットファイル。nil なら stop は何も消さない
    private var boundSocket: FileIdentity?

    private func claimSocketFile() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: socketPath)
        let identity = FileIdentity(path: socketPath)
        lock.withLock { boundSocket = identity }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveLine(connection, buffer: Data())
    }

    private func receiveLine(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                respond(connection, requestData: Data(buffer[..<newlineIndex]))
            } else if error != nil || isComplete || buffer.count >= Self.maxRequestBytes {
                connection.cancel()
            } else {
                receiveLine(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, requestData: Data) {
        Task { [handler] in
            let response: ControlResponse = if let request = try? JSONDecoder().decode(ControlRequest.self, from: requestData) {
                await handler(request)
            } else {
                ControlResponse(ok: false, error: "不正なリクエストです")
            }
            var payload = (try? JSONEncoder().encode(response)) ?? Data(#"{"ok":false}"#.utf8)
            payload.append(UInt8(ascii: "\n"))
            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
