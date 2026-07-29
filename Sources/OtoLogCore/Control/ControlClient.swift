import Foundation
import Network

// MARK: - ControlClient

/// ControlServer へ1コマンドを送って応答を受け取るクライアント（devtool・エージェント用）。
public enum ControlClient {
    /// timeout の既定 15 秒: start はモデル準備を待つため数秒かかる。接続不可は即座に failed で返る
    public static func send(
        _ request: ControlRequest,
        socketPath: String = ControlSocketPath.default(),
        timeout: Duration = .seconds(15)
    ) async throws -> ControlResponse {
        try await withThrowingTaskGroup(of: ControlResponse.self) { group in
            let exchange = Exchange(socketPath: socketPath)
            group.addTask { try await exchange.perform(request) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ControlClientError.timedOut
            }
            guard let response = try await group.next() else {
                throw ControlClientError.connectionFailed("応答がありません")
            }
            group.cancelAll()
            exchange.cancel()
            return response
        }
    }
}

// MARK: - ControlClientError

public enum ControlClientError: Error, LocalizedError {
    case connectionFailed(String)
    case timedOut

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case let .connectionFailed(reason):
            "OtoLog に接続できません（アプリは起動していますか?）: \(reason)"
        case .timedOut:
            "OtoLog からの応答がタイムアウトしました"
        }
    }
}

// MARK: - Exchange

/// 1接続1リクエストの往復。NWConnection の状態遷移とコールバックをこのクラスに閉じ込める
private final class Exchange: @unchecked Sendable {
    // MARK: Lifecycle

    init(socketPath: String) {
        connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
    }

    // MARK: Internal

    func perform(_ request: ControlRequest) async throws -> ControlResponse {
        // キャンセル（タイムアウト等）で connection.cancel() → .cancelled → resume を保証する。
        // これが無いと continuation が未解決のまま TaskGroup の脱出待ちがデッドロックする
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resume = Resume(continuation: continuation)
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.sendRequest(request, resume: resume)
                    case let .waiting(error):
                        // unix socket で接続先が無い場合は .failed でなく .waiting で再試行し続けるため、
                        // 待たずに失敗へ倒す（アプリ未起動の即時検知）
                        resume.once(.failure(ControlClientError.connectionFailed(error.localizedDescription)))
                        self?.connection.cancel()
                    case let .failed(error):
                        resume.once(.failure(ControlClientError.connectionFailed(error.localizedDescription)))
                    case .cancelled:
                        resume.once(.failure(ControlClientError.connectionFailed("接続が閉じられました")))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func cancel() {
        connection.cancel()
    }

    // MARK: Private

    /// withCheckedThrowingContinuation の二重 resume 防止（failed と cancelled は連続で来うる）
    private final class Resume: @unchecked Sendable {
        // MARK: Lifecycle

        init(continuation: CheckedContinuation<ControlResponse, any Error>) {
            self.continuation = continuation
        }

        // MARK: Internal

        func once(_ result: Result<ControlResponse, any Error>) {
            lock.withLock {
                guard let continuation else { return }
                self.continuation = nil
                continuation.resume(with: result)
            }
        }

        // MARK: Private

        private let lock = NSLock()
        private var continuation: CheckedContinuation<ControlResponse, any Error>?
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.bigdra50.OtoLog.ControlClient")

    private func sendRequest(_ request: ControlRequest, resume: Resume) {
        var payload: Data
        do {
            payload = try JSONEncoder().encode(request)
        } catch {
            resume.once(.failure(error))
            return
        }
        payload.append(UInt8(ascii: "\n"))
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            if let error {
                resume.once(.failure(ControlClientError.connectionFailed(error.localizedDescription)))
                return
            }
            self?.receiveResponse(buffer: Data(), resume: resume)
        })
    }

    private func receiveResponse(buffer: Data, resume: Resume) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                do {
                    let response = try JSONDecoder().decode(
                        ControlResponse.self, from: Data(buffer[..<newlineIndex])
                    )
                    resume.once(.success(response))
                } catch {
                    resume.once(.failure(error))
                }
            } else if let error {
                resume.once(.failure(ControlClientError.connectionFailed(error.localizedDescription)))
            } else if isComplete {
                resume.once(.failure(ControlClientError.connectionFailed("応答が途切れました")))
            } else {
                self?.receiveResponse(buffer: buffer, resume: resume)
            }
        }
    }
}
