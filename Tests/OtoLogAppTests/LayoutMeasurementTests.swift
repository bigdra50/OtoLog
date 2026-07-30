import AppKit
import SwiftUI
import Testing

/// レイアウト検証の土台が機能していることを守るテスト。
///
/// PopoverLayoutTests は「要求高さ <= 上限」を見るので、実寸が常に 0 を返す環境では
/// 中身が破綻していても通ってしまう。測定そのものが生きていることを先に固定する。
@MainActor struct LayoutMeasurementTests {
    @Test func 固定サイズのビューは指定どおりの実寸を返す() {
        let hosting = NSHostingController(rootView: Color.clear.frame(width: 340, height: 200))
        let size = hosting.view.fittingSize
        #expect(size.width == 340)
        #expect(size.height == 200)
    }

    @Test func 中身を積み増すと実寸も増える() {
        func height(lines: Int) -> CGFloat {
            let view = VStack(spacing: 0) {
                ForEach(0..<lines, id: \.self) { _ in Text("行").font(.caption) }
            }
            .frame(width: 340)
            return NSHostingController(rootView: view).view.fittingSize.height
        }
        let one = height(lines: 1)
        let ten = height(lines: 10)
        #expect(one > 0)
        #expect(ten > one)
    }
}
