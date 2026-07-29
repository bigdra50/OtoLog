import AppKit
import Observation
import OtoLogCore
import SwiftUI

/// メニューバーの NSStatusItem とポップオーバーを管理する。
@MainActor final class StatusItemController: NSObject {
    // MARK: Lifecycle

    init(
        state: AppState,
        settings: AppSettings,
        coordinator: RecordingCoordinator,
        generation: GenerationCoordinator,
        pipeline: PipelineCoordinator,
        openLibrary: @escaping () -> Void
    ) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        animator = IconAnimator(button: statusItem.button)
        popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                state: state, settings: settings, coordinator: coordinator,
                generation: generation, pipeline: pipeline, openLibrary: openLibrary
            )
        )
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        animator.apply(state.sessionState)
        trackSessionState()
    }

    // MARK: Private

    private let state: AppState
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let animator: IconAnimator

    /// Observation でセッション状態の変化をアイコンへ追従させる
    private func trackSessionState() {
        withObservationTracking {
            _ = state.sessionState
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.animator.apply(self.state.sessionState)
                self.trackSessionState()
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
