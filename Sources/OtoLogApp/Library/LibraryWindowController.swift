import AppKit
import SwiftUI

/// ライブラリウィンドウの管理。ウィンドウは1個を再利用し、
/// 表示のたびに中身を作り直して最新のセッション一覧を読む。
/// LSUIElement アプリのため表示時に明示的に activate する。
@MainActor final class LibraryWindowController {
    // MARK: Lifecycle

    init(settings: AppSettings) {
        self.settings = settings
        generation = LibraryGenerationCoordinator(settings: settings)
    }

    // MARK: Internal

    func show() {
        if window == nil {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            created.title = "OtoLog ライブラリ"
            created.minSize = NSSize(width: 600, height: 400)
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        let hosting = NSHostingController(rootView: LibraryView(settings: settings, generation: generation))
        // SwiftUI の理想サイズでウィンドウが勝手にリサイズされないよう固定し、現在の frame を保つ
        hosting.sizingOptions = []
        let frame = window?.frame
        window?.contentViewController = hosting
        if let frame {
            window?.setFrame(frame, display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Private

    private let settings: AppSettings
    /// ウィンドウを閉じても生成は続くよう、コントローラ側で持つ
    private let generation: LibraryGenerationCoordinator
    private var window: NSWindow?
}
