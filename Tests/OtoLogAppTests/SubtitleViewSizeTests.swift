import AppKit
@testable import OtoLogApp
import SwiftUI
import Testing

/// 字幕パネルの高さは実寸から決める。
/// 幅を確定せずに測ると折り返しが反映されず、長い訳がパネルからはみ出す。
@MainActor struct SubtitleViewSizeTests {
    // MARK: Internal

    let width: CGFloat = 900

    @Test func 訳が長いほど高くなる() {
        let short = height(original: "こんにちは", translation: "Hello")
        let long = height(
            original: "こんにちは",
            translation: String(repeating: "This is a fairly long translated sentence. ", count: 4)
        )

        #expect(short > 0)
        #expect(long > short)
    }

    /// 原文が無いときは行そのものを描かない
    @Test func 原文がないと訳だけの高さになる() {
        let withOriginal = height(original: "こんにちは", translation: "Hello")
        let withoutOriginal = height(original: "", translation: "Hello")

        #expect(withoutOriginal < withOriginal)
    }

    @Test func 指定した幅どおりに収まる() {
        let view = SubtitleView(original: "こんにちは", translation: "Hello", width: width)

        #expect(NSHostingController(rootView: view).view.fittingSize.width == width)
    }

    // MARK: Private

    private func height(original: String, translation: String) -> CGFloat {
        let view = SubtitleView(original: original, translation: translation, width: width)
        return NSHostingController(rootView: view).view.fittingSize.height
    }
}
