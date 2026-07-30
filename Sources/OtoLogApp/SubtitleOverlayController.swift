import AppKit
import SwiftUI

// MARK: - SubtitleView

/// 字幕1枚。原文を小さく上に、訳を大きく下に置く。
struct SubtitleView: View {
    let original: String
    let translation: String
    /// パネル幅。ここで確定させないと fittingSize が折り返し後の高さを返さない
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !original.isEmpty {
                Text(original)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(translation)
                .font(.system(size: 24, weight: .medium))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: width, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - SubtitleOverlayController

/// 記録中の訳を画面へ重ねて出すパネル。
/// メニューバー常駐（.accessory）のまま、アプリを前面化せず、クリックも透過する。
@MainActor final class SubtitleOverlayController {
    // MARK: Internal

    /// 訳が無ければ何も出さない。原文だけの字幕は目的から外れる
    func update(original: String, translation: String) {
        guard !translation.isEmpty else { return }
        render(original: original, translation: translation)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: Private

    private var panel: NSPanel?
    private var hosting: NSHostingView<SubtitleView>?

    private func render(original: String, translation: String) {
        // screens の先頭は必ず原点（メニューバー）を含む画面。NSScreen.main は
        // キーウィンドウのある画面を指すので、常駐アプリからは意図しない画面を掴む
        guard let screen = NSScreen.screens.first else { return }
        let panel = ensurePanel()
        let hosting = ensureHosting(in: panel)

        let width = SubtitleOverlayMetrics.frame(in: screen.visibleFrame, contentHeight: 0).width
        hosting.rootView = SubtitleView(original: original, translation: translation, width: width)
        let height = hosting.fittingSize.height
        panel.setFrame(
            SubtitleOverlayMetrics.frame(in: screen.visibleFrame, contentHeight: height),
            display: true
        )
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let created = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        created.isFloatingPanel = true
        created.hidesOnDeactivate = false
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = false
        // 字幕越しに下のアプリを操作できるようにする
        created.ignoresMouseEvents = true
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // level は isFloatingPanel より後に設定する。順序を逆にすると floating へ戻される
        created.level = .screenSaver
        panel = created
        return created
    }

    private func ensureHosting(in panel: NSPanel) -> NSHostingView<SubtitleView> {
        if let hosting { return hosting }
        let created = NSHostingView(rootView: SubtitleView(original: "", translation: "", width: 0))
        panel.contentView = created
        hosting = created
        return created
    }
}
