import Foundation
@testable import OtoLogApp
import Testing

/// 字幕パネルの配置。画面をまたいでも常に見える位置へ収める。
struct SubtitleOverlayMetricsTests {
    /// 内蔵ディスプレイ相当（原点が 0）
    let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 949)

    @Test func 画面下部の中央に置く() {
        let frame = SubtitleOverlayMetrics.frame(in: builtIn, contentHeight: 120)

        #expect(frame.midX == builtIn.midX)
        #expect(frame.minY == builtIn.minY + SubtitleOverlayMetrics.bottomMargin)
        #expect(frame.height == 120)
    }

    @Test func 幅は画面比率と上限のうち小さい方になる() {
        let narrow = SubtitleOverlayMetrics.frame(
            in: CGRect(x: 0, y: 0, width: 800, height: 600), contentHeight: 100
        )
        #expect(narrow.width == 800 * SubtitleOverlayMetrics.widthRatio)

        let wide = SubtitleOverlayMetrics.frame(
            in: CGRect(x: 0, y: 0, width: 3840, height: 2160), contentHeight: 100
        )
        #expect(wide.width == SubtitleOverlayMetrics.maxWidth)
    }

    /// 原点がずれた外部ディスプレイでも画面内に収まる（座標を取り違えると見失う）
    @Test func 原点がずれた画面でも画面内に収まる() {
        let external = CGRect(x: -337, y: 982, width: 1920, height: 1050)

        let frame = SubtitleOverlayMetrics.frame(in: external, contentHeight: 120)

        #expect(external.contains(frame))
    }

    /// 長文でも画面外へはみ出さない
    @Test func 内容が高くても画面内に収める() {
        let frame = SubtitleOverlayMetrics.frame(in: builtIn, contentHeight: 5000)

        #expect(frame.maxY <= builtIn.maxY)
        #expect(builtIn.contains(frame))
    }
}
