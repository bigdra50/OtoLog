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
    }

    // MARK: Private

    private var statusItemController: StatusItemController?
    private var coordinator: RecordingCoordinator?
    private var generation: GenerationCoordinator?
    private var pipeline: PipelineCoordinator?
    private var library: LibraryWindowController?
}
