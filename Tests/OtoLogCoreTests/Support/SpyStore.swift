import Foundation
@testable import OtoLogCore

/// TranscriptStore のテストダブル。呼び出しを記録し、指定エラーを投げられる。
actor SpyStore: TranscriptStore {
    // MARK: Internal

    private(set) var beganContexts: [TranscriptionContext] = []
    private(set) var segments: [TranscriptSegment] = []
    private(set) var finalizedAts: [Date] = []
    /// finalize に渡された終わり方。呼ばれた順
    private(set) var finalizedReasons: [SessionEndReason] = []

    /// finalize が返す参照。既定はディレクトリ名固定のダミー
    var finalizeResult: SessionRef? = SessionRef(
        directoryName: "2026-07-29_1300",
        title: nil,
        startedAt: Date(timeIntervalSince1970: 1_785_297_600)
    )

    /// 呼び出し順の検証用フック
    var onFinalize: (@Sendable () -> Void)?
    var onAppend: (@Sendable () -> Void)?

    func begin(context: TranscriptionContext) throws {
        if let beginError { throw beginError }
        beganContexts.append(context)
    }

    func append(_ segment: TranscriptSegment) throws {
        if let errorToThrow { throw errorToThrow }
        segments.append(segment)
        onAppend?()
    }

    func finalize(endedAt: Date, reason: SessionEndReason) throws -> SessionRef? {
        finalizedAts.append(endedAt)
        finalizedReasons.append(reason)
        onFinalize?()
        return beganContexts.isEmpty ? nil : finalizeResult
    }

    func setError(_ error: (any Error)?) {
        errorToThrow = error
    }

    func setBeginError(_ error: (any Error)?) {
        beginError = error
    }

    func setOnFinalize(_ hook: (@Sendable () -> Void)?) {
        onFinalize = hook
    }

    func setOnAppend(_ hook: (@Sendable () -> Void)?) {
        onAppend = hook
    }

    func setFinalizeResult(_ ref: SessionRef?) {
        finalizeResult = ref
    }

    // MARK: Private

    private var errorToThrow: (any Error)?
    private var beginError: (any Error)?
}
