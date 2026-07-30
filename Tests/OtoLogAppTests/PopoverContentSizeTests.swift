import AppKit
@testable import OtoLogApp
import Testing

// MARK: - PopoverContentSizeTests

/// 中身が要求する高さを、画面に収まるサイズへ丸めることを守るテスト。
///
/// 高さそのものは崩れの原因ではない（実測では 420pt でも 949pt の画面で崩れた）。
/// 崩れは NSPopover の再配置側の問題で、そちらは PopoverPlacementTests が見る。
/// ここが守るのは「画面より高いポップオーバーを要求しない」ことだけ。
@MainActor struct PopoverContentSizeTests {
    /// Dock を出している内蔵ディスプレイや、背の低い外部モニタに相当
    static let shortScreenHeight: CGFloat = 700

    @Test func 生成と設定を開きタスクが並んだ要求高さは画面に収まる大きさへ丸まる() {
        let fixture = PopoverFixture(taskCount: 8)
        let wanted = CGSize(
            width: PopoverMetrics.width,
            height: fixture.measuredHeight(
                showsGeneration: true,
                showsSettings: true,
                generationMode: .playbook
            )
        )
        let resolved = PopoverMetrics.resolvedContentSize(
            wanted: wanted,
            visibleHeights: [Self.shortScreenHeight]
        )
        let limit = PopoverMetrics.maxHeight(visibleHeight: Self.shortScreenHeight)
        #expect(resolved.height <= limit)
        #expect(resolved.width == PopoverMetrics.width)
    }

    @Test func タスクが増え続けても丸めた高さは上限で頭を打つ() {
        let fixture = PopoverFixture(taskCount: 40)
        let natural = fixture.measuredHeight(
            showsGeneration: true,
            showsSettings: true,
            generationMode: .playbook
        )
        let limit = PopoverMetrics.maxHeight(visibleHeight: Self.shortScreenHeight)
        // 前提: 素の要求はこの画面に収まらないほど高い
        #expect(natural > limit)

        let resolved = PopoverMetrics.resolvedContentSize(
            wanted: CGSize(width: PopoverMetrics.width, height: natural),
            visibleHeights: [Self.shortScreenHeight]
        )
        #expect(resolved.height == limit)
    }

    @Test func 収まる高さはそのまま通す() {
        let wanted = CGSize(width: PopoverMetrics.width, height: 420)
        let resolved = PopoverMetrics.resolvedContentSize(wanted: wanted, visibleHeights: [949])
        #expect(resolved.height == 420)
    }

    @Test func 複数画面では最も背の低い画面に合わせる() {
        let wanted = CGSize(width: PopoverMetrics.width, height: 1000)
        let resolved = PopoverMetrics.resolvedContentSize(wanted: wanted, visibleHeights: [1080, 949])
        #expect(resolved.height == PopoverMetrics.maxHeight(visibleHeight: 949))
    }
}

// MARK: - PopoverMetricsTests

/// 上限そのものの計算
struct PopoverMetricsTests {
    @Test func 画面の可視高さから余白を引いた値を返す() {
        #expect(PopoverMetrics.maxHeight(visibleHeight: 1000, margin: 48) == 952)
    }

    @Test func 極端に低い画面でも操作できる下限は割らない() {
        #expect(PopoverMetrics.maxHeight(visibleHeight: 200) == PopoverMetrics.minimumHeight)
    }

    @Test func 画面が取れないときは控えめな既定値から求める() {
        #expect(PopoverMetrics.maxHeight(visibleHeights: []) == PopoverMetrics.maxHeight(visibleHeight: 720))
    }
}
