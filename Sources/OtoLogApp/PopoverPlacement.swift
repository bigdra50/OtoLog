import AppKit

/// 開いたポップオーバーが画面のどこに置かれたか。
/// 崩れを記録に残して、後から「はみ出していたか」を判定できるようにする。
///
/// 座標はすべて画面座標（左下原点・y 上向き）。上へのはみ出しは maxY 側に出る。
struct PopoverPlacement {
    /// ステータス項目のボタン矩形
    let anchor: CGRect
    /// 実際に置かれたポップオーバーのウィンドウ矩形
    let popover: CGRect
    /// アンカーが載っている画面の可視領域
    let screenVisible: CGRect

    /// 可視領域の上端から外へ出た量。
    /// 正常でも矢印がメニューバーへ接するぶん数 pt は出るので、判定ではなく診断に使う
    var overflowTop: CGFloat {
        max(0, popover.maxY - screenVisible.maxY)
    }

    var overflowBottom: CGFloat {
        max(0, screenVisible.minY - popover.minY)
    }

    /// アンカーの上端を越えずに生えているか。
    /// 越えていれば header やツールバーがメニューバーの外へ出て見えなくなっている
    var opensDownwardFromAnchor: Bool {
        popover.maxY <= anchor.maxY
    }

    /// 置かれ方が壊れているか。
    /// 上はアンカー基準で見る（可視領域基準だと矢印のぶんを毎回異常と数えてしまう）
    var isMisplaced: Bool {
        !opensDownwardFromAnchor || overflowBottom > 0
    }

    /// ログ1行。異常時に必要な数値だけを並べる
    var summary: String {
        let size = "\(Int(popover.width))x\(Int(popover.height))"
        return [
            "popover=\(size)",
            "popoverY=\(Int(popover.minY))..\(Int(popover.maxY))",
            "anchorY=\(Int(anchor.minY))..\(Int(anchor.maxY))",
            "visibleY=\(Int(screenVisible.minY))..\(Int(screenVisible.maxY))",
            "overflowTop=\(Int(overflowTop))",
            "overflowBottom=\(Int(overflowBottom))",
            "downward=\(opensDownwardFromAnchor)",
            "misplaced=\(isMisplaced)",
        ].joined(separator: " ")
    }
}
