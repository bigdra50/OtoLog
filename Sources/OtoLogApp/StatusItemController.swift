import AppKit
import Observation
import OtoLogCore
import SwiftUI

// MARK: - StatusItemController

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
        // OTOLOG_UI_PROBE=1 で、最も背が高くなる構成を開いた状態から始める。
        // 置かれ方の崩れは再現性が低く、通常操作では狙って出せないため回帰確認の入口として残す
        let probe = ProcessInfo.processInfo.environment["OTOLOG_UI_PROBE"] == "1"
        let hosting = NSHostingController(
            rootView: PopoverView(
                state: state, settings: settings, coordinator: coordinator,
                generation: generation, pipeline: pipeline, openLibrary: openLibrary,
                showsGeneration: probe, showsSettings: probe,
                generationMode: probe ? .playbook : .single
            )
        )
        popover.contentViewController = hosting
        popover.delegate = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        animator.apply(state.sessionState)
        trackSessionState()

        if probe {
            // 講演プレイブックの完了後に相当する行数を並べる
            state.pipelineTasks = ["誤り訂正", "要約", "用語集", "質疑応答の抽出", "追試検討", "参照リンク", "共有パッケージ"]
                .enumerated()
                .map { index, name in
                    PipelineTaskDisplay(
                        id: "probe-\(index)",
                        displayName: name,
                        state: PipelineTaskState(status: .done),
                        snippet: nil
                    )
                }
        }

        // 生成・設定の開閉で中身の高さが変わる。その瞬間に位置が崩れていないかを見たいので購読する
        hosting.view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentFrameChanged),
            name: NSView.frameDidChangeNotification,
            object: hosting.view
        )
    }

    // MARK: Private

    private let state: AppState
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let animator: IconAnimator
    /// 同じ置かれ方を重複して記録しないための直前の値
    private var lastPlacementSummary: String?

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

    @objc private func contentFrameChanged() {
        guard popover.isShown else { return }
        // 是正の前に記録する。先に直すと崩れていた事実がログに残らない
        recordPlacement(reason: "resized")
        realignToAnchor()
        recordPlacement(reason: "realigned")
    }

    /// NSPopover は表示中に中身の高さが変わると、アンカー基準で開き直さず
    /// それまでの矩形の中心を保って上下へ伸びる。伸びた上端はメニューバーを越えて画面外に出て、
    /// header やツールバーが見えなくなる。
    ///
    /// contentSize を SwiftUI の要求どおりに入れ直してから、アンカー矩形を再設定して
    /// 下向きの配置へ戻す。positioningRect だけを触ると contentSize が古い値に戻り、
    /// 中身が切り詰められる
    private func realignToAnchor() {
        guard let button = statusItem.button,
              let content = popover.contentViewController?.view
        else { return }
        let wanted = content.fittingSize
        guard wanted.height > 0 else { return }
        // どの画面に開いても収まる高さで頭を打たせる。超えるぶんは表示しきれないが位置は保つ
        let resolved = PopoverMetrics.resolvedContentSize(wanted: wanted)
        if abs(popover.contentSize.height - resolved.height) > 1
            || abs(popover.contentSize.width - resolved.width) > 1 {
            popover.contentSize = resolved
        }
        popover.positioningRect = button.bounds
    }

    /// 実際の置かれ方を残す。
    /// 崩れは再現性が低く、スクリーンショットからは数値が取れないため常時記録する
    private func recordPlacement(reason: String) {
        guard let button = statusItem.button,
              let buttonWindow = button.window
        else {
            UILog.info("popover \(reason): アンカーが取れず記録できない")
            return
        }
        guard let popoverFrame = popover.contentViewController?.view.window?.frame else {
            UILog.info("popover \(reason): ウィンドウがまだ無く記録できない")
            return
        }
        let anchorOnScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        // アンカーが載っている画面を優先する。ポップオーバーはそこに開く
        let screen = buttonWindow.screen
            ?? NSScreen.screens.first { $0.frame.intersects(popoverFrame) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            UILog.info("popover \(reason): 画面が取れず記録できない")
            return
        }
        let placement = PopoverPlacement(
            anchor: anchorOnScreen,
            popover: popoverFrame,
            screenVisible: visible
        )
        // 同じ状態を繰り返し書かない。アニメーション中に何度も通るため
        guard placement.summary != lastPlacementSummary else { return }
        lastPlacementSummary = placement.summary

        let message = "popover \(reason): \(placement.summary) screens=\(NSScreen.screens.count)"
        if placement.isMisplaced {
            UILog.fault(message)
        } else {
            UILog.info(message)
        }
    }
}

// MARK: NSPopoverDelegate

extension StatusItemController: NSPopoverDelegate {
    /// show() の直後はまだ最終位置に落ち着いていないので、確定後に記録する
    func popoverDidShow(_: Notification) {
        recordPlacement(reason: "shown")
        // 開いた時点で既に伸びていることがある（開く前に中身の高さが確定した場合）
        realignToAnchor()
        recordPlacement(reason: "realigned")
    }

    func popoverDidClose(_: Notification) {
        lastPlacementSummary = nil
    }
}
