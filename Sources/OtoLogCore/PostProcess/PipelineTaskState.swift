import Foundation

/// パイプライン内の1タスクの実行状態。meta.json に永続化され、
/// アプリ再起動後の表示・失敗タスクの再実行に使う。
public struct PipelineTaskState: Sendable, Equatable, Codable {
    // MARK: Lifecycle

    public init(
        status: Status = .pending,
        outputFile: String? = nil,
        error: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.status = status
        self.outputFile = outputFile
        self.error = error
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    // MARK: Public

    public enum Status: String, Sendable, Codable {
        case pending
        case running
        case done
        case failed
        /// 依存タスクの失敗により実行しなかった
        case skipped
    }

    public var status: Status
    public var outputFile: String?
    public var error: String?
    public var startedAt: Date?
    public var finishedAt: Date?
}
