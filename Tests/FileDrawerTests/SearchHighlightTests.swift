import XCTest
import SwiftUI
@testable import FileDrawer

/// 搜索命中高亮的 run 属性契约。
/// 背景：run 级前景色 / 字体必须写进 AppKit scope（NSColor / NSFont）——SwiftUI scope
/// 的 Color·Font run 属性会被实机 Text 渲染路径整体丢弃（高亮整个不可见），而离屏
/// ImageRenderer 却渲染正常，回归极易漏网。本组测试锁定「属性落在 AppKit scope」。
final class SearchHighlightTests: XCTestCase {
    /// 带高亮属性（AppKit scope 前景色）的 run 所覆盖的文本片段
    private func highlightedRunTexts(_ attributed: AttributedString) -> [String] {
        attributed.runs.compactMap { run in
            guard run.appKit.foregroundColor != nil else { return nil }
            return String(attributed[run.range].characters)
        }
    }

    /// 命中片段带 AppKit scope 的前景色与加粗字体（实机可见性的充要契约）
    func testMatchedRunCarriesAppKitScopeAttributes() {
        let attr = SearchNameHighlight.attributed("square.jpg", keywords: ["JPG"], fontSize: 12.5)

        let highlightedTexts = highlightedRunTexts(attr)
        XCTAssertEqual(highlightedTexts, ["jpg"], "只有命中片段带高亮（大小写不敏感）")

        let font: NSFont? = attr.runs.first { $0.appKit.foregroundColor != nil }?.appKit.font
        XCTAssertEqual(font, .boldSystemFont(ofSize: 12.5), "命中片段加粗，字号随行名称字号")
    }

    /// 高亮色是明暗自适应 NSColor 原体（与 DrawerTheme.accent 同源）
    func testAccentNSColorMatchesThemeHex() throws {
        func rgb(_ color: NSColor, under appearance: NSAppearance) -> (Double, Double, Double) {
            let previous = NSAppearance.current
            NSAppearance.current = appearance
            defer { NSAppearance.current = previous }
            let resolved = color.usingColorSpace(.deviceRGB)!
            return (Double(resolved.redComponent), Double(resolved.greenComponent), Double(resolved.blueComponent))
        }
        func components(_ hex: UInt32) -> (Double, Double, Double) {
            let c = NSColor(hex: hex).usingColorSpace(.deviceRGB)!
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        func assertClose(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) {
            XCTAssertEqual(a.0, b.0, accuracy: 0.001)
            XCTAssertEqual(a.1, b.1, accuracy: 0.001)
            XCTAssertEqual(a.2, b.2, accuracy: 0.001)
        }
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))

        assertClose(rgb(DrawerTheme.accentNSColor, under: light), components(0x6C5CE7))
        assertClose(rgb(DrawerTheme.accentNSColor, under: dark), components(0x8F7FF2))
    }

    /// 未命中 / 空关键词：返回原文且无高亮 run
    func testNoKeywordsLeavesTextPlain() {
        let cases: [[String]] = [[], ["mp4"], ["zzz"]]
        for keywords in cases {
            let attr = SearchNameHighlight.attributed("square.jpg", keywords: keywords, fontSize: 13)
            XCTAssertTrue(highlightedRunTexts(attr).isEmpty)
            XCTAssertEqual(String(attr.characters), "square.jpg")
        }
    }

    /// 多关键词、多处命中：所有命中片段都被标出（相邻命中属性相同合并为一个 run）
    func testMultipleKeywordsAllHighlighted() {
        let attr = SearchNameHighlight.attributed("报告v2.final.pdf", keywords: ["报", "PDF", "."], fontSize: 13)
        // 「报」；「final」里的「.」；末尾「.pdf」（「.」与「pdf」相邻且属性相同 → 合并）
        XCTAssertEqual(Set(highlightedRunTexts(attr)), Set(["报", ".", ".pdf"]))
    }
}
