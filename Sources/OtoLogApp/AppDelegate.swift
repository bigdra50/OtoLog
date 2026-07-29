import AppKit
import OtoLogCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: Internal

    func applicationDidFinishLaunching(_: Notification) {
        let state = AppState()
        let settings = AppSettings()
        let coordinator = RecordingCoordinator.makeDefault(state: state, settings: settings)
        coordinator.startObserving()
        let generation = GenerationCoordinator(state: state, settings: settings)
        let pipeline = PipelineCoordinator(state: state, settings: settings)
        let library = LibraryWindowController(settings: settings)
        generation.pipeline = pipeline
        coordinator.onSessionFinished = { [weak generation] ref in
            generation?.handleSessionFinished(ref)
        }
        statusItemController = StatusItemController(
            state: state, settings: settings, coordinator: coordinator,
            generation: generation, pipeline: pipeline,
            openLibrary: { [weak library] in library?.show() }
        )
        self.coordinator = coordinator
        self.generation = generation
        self.pipeline = pipeline
        self.library = library

        // CLI・エージェントからの制御経路（otolog-devtool ctl <status|start|stop>）
        let controlServer = ControlServer(socketPath: ControlSocketPath.default()) {
            [weak coordinator] request in
            guard let coordinator else {
                return ControlResponse(ok: false, error: "終了処理中です")
            }
            return switch request.command {
            case .status: await coordinator.controlStatus()
            case .start: await coordinator.controlStart()
            case .stop: await coordinator.controlStop()
            }
        }
        do {
            try controlServer.start()
            self.controlServer = controlServer
        } catch {
            // 制御ソケットは補助経路。失敗してもアプリ本体は動かす
            NSLog("ControlServer start failed: \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_: Notification) {
        controlServer?.stop()
    }

    // MARK: Private

    private var statusItemController: StatusItemController?
    private var coordinator: RecordingCoordinator?
    private var generation: GenerationCoordinator?
    private var pipeline: PipelineCoordinator?
    private var library: LibraryWindowController?
    private var controlServer: ControlServer?
}
