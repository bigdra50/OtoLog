import Foundation

/// 字幕パネルの配置計算。
enum SubtitleOverlayMetrics {
    /// 横に伸びすぎると視線移動が大きくなるため頭を抑える
    static let maxWidth: CGFloat = 900
    static let widthRatio: CGFloat = 0.7
    /// 画面下端からの余白。フルスクリーン時の再生コントロールと重なりにくい高さ
    static let bottomMargin: CGFloat = 120

    /// screen には visibleFrame を渡す（Dock とメニューバーを避けるため）。
    /// 原点が 0 でない外部ディスプレイでも成り立つよう、すべて screen の座標系で組む
    static func frame(in screen: CGRect, contentHeight: CGFloat) -> CGRect {
        let width = min(maxWidth, screen.width * widthRatio)
        let height = min(contentHeight, screen.height - bottomMargin)
        return CGRect(
            x: screen.midX - width / 2,
            y: screen.minY + bottomMargin,
            width: width,
            height: height
        )
    }
}
