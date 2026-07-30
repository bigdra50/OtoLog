import AppKit

/// メニューバー直下に開くポップオーバーの寸法。
enum PopoverMetrics {
    // MARK: Internal

    /// 横幅は内容に関わらず固定。行の折り返し位置を安定させるため
    static let width: CGFloat = 340

    /// これ以上狭めると操作できなくなる下限。極端に低い画面ではスクロールに委ねる
    static let minimumHeight: CGFloat = 240

    /// ポップオーバー本体が使える最大高さ。
    /// NSPopover は要求サイズがアンカー下に収まらないと位置をずらして辻褄を合わせ、
    /// 上端がメニューバーの外へ出る。そうなる前にこちらで頭を打たせる。
    /// margin は矢印・影と、下端に残す余白の分。
    static func maxHeight(visibleHeight: CGFloat, margin: CGFloat = 48) -> CGFloat {
        max(minimumHeight, visibleHeight - margin)
    }

    /// 最も背の低い画面に合わせる。
    /// ポップオーバーはメニューバーを移した先の画面に開くので、どの画面でも収まる高さにする
    static func maxHeight(visibleHeights: [CGFloat], margin: CGFloat = 48) -> CGFloat {
        maxHeight(visibleHeight: visibleHeights.min() ?? fallbackVisibleHeight, margin: margin)
    }

    /// 接続中の画面から求める
    @MainActor static func maxHeightForConnectedScreens() -> CGFloat {
        maxHeight(visibleHeights: NSScreen.screens.map(\.visibleFrame.height))
    }

    /// SwiftUI が要求したサイズを、画面に収まる大きさへ丸める。
    /// 幅は中身の折り返しが決まっているのでそのまま通す
    static func resolvedContentSize(wanted: CGSize, visibleHeights: [CGFloat]) -> CGSize {
        CGSize(
            width: wanted.width,
            height: min(wanted.height, maxHeight(visibleHeights: visibleHeights))
        )
    }

    /// 接続中の画面で丸める
    @MainActor static func resolvedContentSize(wanted: CGSize) -> CGSize {
        resolvedContentSize(wanted: wanted, visibleHeights: NSScreen.screens.map(\.visibleFrame.height))
    }

    // MARK: Private

    /// 画面が取れないときの控えめな既定値
    private static let fallbackVisibleHeight: CGFloat = 720
}
