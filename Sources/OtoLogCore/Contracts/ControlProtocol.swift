import Foundation

// MARK: - ControlCommand

/// 外部（CLI・エージェント）からアプリを操作するコマンド。
/// UI と同じ操作を正規経路で提供し、AX 操作（誤爆リスク）なしで自動化できるようにする。
public enum ControlCommand: String, Codable, Sendable {
    case status
    case start
    case stop
}

// MARK: - ControlRequest

public struct ControlRequest: Codable, Sendable {
    // MARK: Lifecycle

    public init(command: ControlCommand) {
        self.command = command
    }

    // MARK: Public

    public let command: ControlCommand
}

// MARK: - ControlResponse

public struct ControlResponse: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(ok: Bool, error: String? = nil, state: String? = nil, sessionPath: String? = nil) {
        self.ok = ok
        self.error = error
        self.state = state
        self.sessionPath = sessionPath
    }

    // MARK: Public

    public let ok: Bool
    public let error: String?
    /// idle | preparing | recording | stopping | failed
    public let state: String?
    /// 最新セッションの保存先相対パス（記録中はそのセッション）
    public let sessionPath: String?
}

// MARK: - ControlSocketPath

public enum ControlSocketPath {
    /// XDG_STATE_HOME（未設定なら ~/.local/state）/otolog/control.sock。
    /// unix socket のパス長上限（104 バイト）に収まる場所に置く
    public static func `default`(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let stateHome = environment["XDG_STATE_HOME"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state", isDirectory: true)
        return stateHome.appendingPathComponent("otolog/control.sock").path
    }
}
