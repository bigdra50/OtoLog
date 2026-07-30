@preconcurrency import AVFAudio
import Foundation
@testable import OtoLogApp
import OtoLogCore
import SwiftUI

// MARK: - IdleCaptureSource

/// レイアウト検証用。音声には触らせない。
/// 呼ばれたら失敗させて、測定のはずが録音を始めていた事故を検知する
struct IdleCaptureSource: AudioCaptureSource {
    func start(targetFormat _: AVAudioFormat) async throws -> AsyncThrowingStream<AudioChunk, any Error> {
        throw LayoutFixtureMisuse.audioTouched
    }

    func stop() async {}
}

// MARK: - IdleTranscriptionEngine

struct IdleTranscriptionEngine: TranscriptionEngine {
    func prepare(locales _: [Locale], onProgress _: @escaping @Sendable (Double) -> Void) async throws -> AVAudioFormat {
        throw LayoutFixtureMisuse.audioTouched
    }

    func start(
        chunks _: AsyncThrowingStream<AudioChunk, any Error>,
        context _: TranscriptionContext
    ) async throws -> AsyncThrowingStream<TranscriptEvent, any Error> {
        throw LayoutFixtureMisuse.audioTouched
    }

    func finish() async {}
}

// MARK: - IdleTranscriptStore

struct IdleTranscriptStore: TranscriptStore {
    func begin(context _: TranscriptionContext) async throws {
        throw LayoutFixtureMisuse.storeTouched
    }

    func append(_: TranscriptSegment) async throws {
        throw LayoutFixtureMisuse.storeTouched
    }

    func finalize(endedAt _: Date) async throws -> SessionRef? {
        throw LayoutFixtureMisuse.storeTouched
    }
}

// MARK: - LayoutFixtureMisuse

enum LayoutFixtureMisuse: Error {
    case audioTouched
    case storeTouched
}

// MARK: - PopoverFixture

/// ポップオーバーのレイアウトを測るための組み立て。
@MainActor struct PopoverFixture {
    // MARK: Lifecycle

    init(taskCount: Int, runningTaskWithSnippet: Bool = false, storeError: String? = nil) {
        // 実利用中の設定を書き換えないよう、専用ドメインの defaults を使う
        let defaults = UserDefaults(suiteName: "OtoLogAppTests.popover-layout") ?? .standard
        settings = AppSettings(defaults: defaults)
        // 「自動実行プレイブック」の行が増える最も背の高い組み合わせを再現する
        settings.postStopAction = .titleAndPipeline

        state = AppState()
        let session = RecordingSession(
            capture: IdleCaptureSource(),
            engine: IdleTranscriptionEngine(),
            store: IdleTranscriptStore()
        )
        let store = SessionFileStore(
            directory: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "otolog-layout-probe"),
            timeZone: TimeZone(identifier: "Asia/Tokyo") ?? .current
        )
        coordinator = RecordingCoordinator(session: session, store: store, state: state, settings: settings)
        generation = GenerationCoordinator(state: state, settings: settings)
        pipeline = PipelineCoordinator(state: state, settings: settings)

        state.generationSessions = [
            SessionRef(
                directoryName: "2026-07-29/ドンキーコングバランザのボクセル技術",
                title: "ドンキーコングバランザのボクセル技術",
                startedAt: Date(timeIntervalSince1970: 1_785_060_000)
            ),
        ]
        state.pipelinePlaybooks = [
            Playbook(id: "lecture", displayName: "講演", tasks: []),
        ]
        state.pipelineTasks = (0..<taskCount).map { index in
            PipelineTaskDisplay(
                id: "task-\(index)",
                displayName: ["要約", "誤り訂正", "用語集", "質疑応答の抽出", "追加検討", "共有パッケージ", "再現手順", "参照リンク"][index % 8],
                state: PipelineTaskState(status: .done),
                snippet: nil
            )
        }
        state.storeErrorMessage = storeError
        if runningTaskWithSnippet, !state.pipelineTasks.isEmpty {
            state.pipelineTasks[0].state = PipelineTaskState(status: .running)
            state.pipelineTasks[0].snippet = "生成中の出力末尾がここに 2 行ぶん表示される。動いていることの生存確認のための表示。"
        }
    }

    // MARK: Internal

    /// 外部ボリュームの保存先が TCC 未承認だったときに出る種類の文言。
    /// 長いパスを含み、340pt 幅では何行にも折り返す
    static let longStoreError = "保存先 /Volumes/CrucialX9/dev/github.com/bigdra50/OtoLog/logs/2026-07-29 "
        + "への書き込みが macOS に許可されていません。"
        + "システム設定のプライバシーとセキュリティからフルディスクアクセスを与えて、アプリを再起動してください。"

    let state: AppState
    let settings: AppSettings
    let coordinator: RecordingCoordinator
    let generation: GenerationCoordinator
    let pipeline: PipelineCoordinator

    /// 実際にホストして測った高さ。ポップオーバーが要求する寸法そのもの
    func measuredHeight(
        showsGeneration: Bool,
        showsSettings: Bool,
        generationMode: PopoverView.GenerationMode = .single
    ) -> CGFloat {
        let view = PopoverView(
            state: state,
            settings: settings,
            coordinator: coordinator,
            generation: generation,
            pipeline: pipeline,
            openLibrary: {},
            showsGeneration: showsGeneration,
            showsSettings: showsSettings,
            generationMode: generationMode
        )
        return NSHostingController(rootView: view).view.fittingSize.height
    }
}
