import Foundation
import Observation
import OtoLogCore

// MARK: - GenerationState

/// 後処理生成の表示状態。
enum GenerationState: Equatable {
    case idle
    case running(templateName: String)
    case finished(URL)
    case failed(String)
}

// MARK: - PipelineTaskDisplay

/// パイプラインのタスク1行の表示情報。
struct PipelineTaskDisplay: Equatable, Identifiable {
    let id: String
    let displayName: String
    var state: PipelineTaskState
    /// 実行中の生成テキスト末尾（生存確認のライブ表示。永続化しない）
    var snippet: String?
}

// MARK: - AppState

/// 表示用の状態だけを持つ。ロジックは持たない。
@MainActor @Observable final class AppState {
    var sessionState: SessionState = .idle
    var liveText = ""
    var lastSegmentText = ""
    /// 直近セグメントの訳。翻訳オフ・訳せなかったときは空
    var lastSegmentTranslation = ""
    var preparationProgress: Double = 0
    var storeErrorMessage: String?
    var translationErrorMessage: String?

    var generationState: GenerationState = .idle
    var generationSessions: [SessionRef] = []
    var generationTemplates: [GenerationTemplate] = []

    var pipelinePlaybooks: [Playbook] = []
    var pipelineTasks: [PipelineTaskDisplay] = []
    var pipelineRunning = false

    var stewardFindings: [StewardFinding] = []

    var isRecording: Bool {
        sessionState == .recording
    }
}
