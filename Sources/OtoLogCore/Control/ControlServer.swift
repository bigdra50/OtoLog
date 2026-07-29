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
        // bind は start 後に非同期で行われるため、ソケットファイルができた .ready 時点で絞る
        listener.stateUpdateHandler = { [socketPath] state in
            if case .ready = state {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: socketPath
                )
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: Private

    /// 制御コマンドは小さい JSON のみ。これを超える入力は不正として切断する
    private static let maxRequestBytes = 64 * 1024

    private let socketPath: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.bigdra50.OtoLog.ControlServer")
    private var listener: NWListener?

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
