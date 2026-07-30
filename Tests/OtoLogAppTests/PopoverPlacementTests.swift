import AppKit
@testable import OtoLogApp
import Testing

/// 実際に開いたポップオーバーが画面からはみ出したかの判定。
/// 崩れを「スクリーンショットを見て気づく」から「記録に残る」へ移すための土台。
///
/// macOS の画面座標は左下原点・y 上向き。上へのはみ出しは maxY 側で起きる。
struct PopoverPlacementTests {
    /// メニューバーぶんを除いた可視領域。1080 の画面で上 25pt がメニューバー
    static let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055)

    @Test func アンカー下に収まっていればはみ出しなし() {
        let placement = PopoverPlacement(
            anchor: CGRect(x: 1600, y: 1055, width: 24, height: 24),
            popover: CGRect(x: 1450, y: 400, width: 340, height: 650),
            screenVisible: Self.visible
        )
        #expect(!placement.isMisplaced)
        #expect(placement.overflowTop == 0)
        #expect(placement.overflowBottom == 0)
    }

    @Test func 上端が可視領域を超えたらはみ出し量を返す() {
        // header やツールバーが画面外に消えるのがこの状態
        let placement = PopoverPlacement(
            anchor: CGRect(x: 1600, y: 1055, width: 24, height: 24),
            popover: CGRect(x: 1450, y: 500, width: 340, height: 725),
            screenVisible: Self.visible
        )
        #expect(placement.isMisplaced)
        #expect(placement.overflowTop == 170)
        #expect(placement.overflowBottom == 0)
    }

    @Test func 下端が可視領域を割ってもはみ出しとして扱う() {
        let placement = PopoverPlacement(
            anchor: CGRect(x: 1600, y: 1055, width: 24, height: 24),
            popover: CGRect(x: 1450, y: -40, width: 340, height: 600),
            screenVisible: Self.visible
        )
        #expect(placement.isMisplaced)
        #expect(placement.overflowBottom == 40)
    }

    @Test func アンカー直下から下向きに開いていない場合を検出する() {
        // アンカーより上に生えているなら preferredEdge が効いていない
        let placement = PopoverPlacement(
            anchor: CGRect(x: 1600, y: 1055, width: 24, height: 24),
            popover: CGRect(x: 1450, y: 1060, width: 340, height: 300),
            screenVisible: Self.visible
        )
        #expect(!placement.opensDownwardFromAnchor)
    }

    /// 内蔵ディスプレイ（frame 982 / visible 949）で実測した値。
    /// アンカーはメニューバー上にあるため可視領域の外に居る
    @Test func 矢印がメニューバーへ接するぶんのはみ出しは崩れとみなさない() {
        let placement = PopoverPlacement(
            anchor: CGRect(x: 928, y: 951, width: 24, height: 29),
            popover: CGRect(x: 745, y: 534, width: 366, height: 420),
            screenVisible: CGRect(x: 0, y: 0, width: 1512, height: 949)
        )
        #expect(!placement.isMisplaced)
        #expect(placement.opensDownwardFromAnchor)
        // 可視領域は 5pt 超えるが、これは矢印がメニューバーに接するぶん
        #expect(placement.overflowTop == 5)
    }

    /// 中身の高さが変わったとき NSPopover が中心を保って上下へ伸びた状態。実測値
    @Test func 中心を保って上へ伸びた状態を崩れとして検出する() {
        let placement = PopoverPlacement(
            anchor: CGRect(x: 928, y: 951, width: 24, height: 29),
            popover: CGRect(x: 745, y: 608, width: 366, height: 420),
            screenVisible: CGRect(x: 0, y: 0, width: 1512, height: 949)
        )
        #expect(placement.isMisplaced)
        #expect(!placement.opensDownwardFromAnchor)
        #expect(placement.overflowTop == 79)
    }

    @Test func 記録用の一行はフレームとはみ出し量を含む() {
        let placement = PopoverPlacement(
            anchor: CGRect(x: 1600, y: 1055, width: 24, height: 24),
            popover: CGRect(x: 1450, y: 500, width: 340, height: 725),
            screenVisible: Self.visible
        )
        let line = placement.summary
        #expect(line.contains("overflowTop=170"))
        #expect(line.contains("340x725"))
        #expect(line.contains("misplaced=true"))
    }
}
