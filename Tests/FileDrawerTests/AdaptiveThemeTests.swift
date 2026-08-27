import XCTest
import AppKit
@testable import FileDrawer

/// 品牌色明暗自适应：深色外观解析出更亮的色值
final class AdaptiveThemeTests: XCTestCase {

    private func rgb(_ color: NSColor, under appearance: NSAppearance) -> (Double, Double, Double)? {
        // 动态色的 provider 按当前外观解析：临时切换 NSAppearance.current 再读值
        let previous = NSAppearance.current
        NSAppearance.current = appearance
        defer { NSAppearance.current = previous }
        guard let resolved = color.usingColorSpace(.deviceRGB) else { return nil }
        return (Double(resolved.redComponent), Double(resolved.greenComponent), Double(resolved.blueComponent))
    }

    /// 深色模式下的品牌色应比浅色模式亮（对比度调优的意图）
    func testAccentIsBrighterInDarkAppearance() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))

        let base = DrawerTheme.adaptiveNSColor(light: 0x6C5CE7, dark: 0x8F7FF2)
        let lightRGB = try XCTUnwrap(rgb(base, under: light))
        let darkRGB = try XCTUnwrap(rgb(base, under: dark))

        XCTAssertGreaterThan(darkRGB.0, lightRGB.0, "深色模式红色分量应更亮")
        XCTAssertGreaterThan(darkRGB.1, lightRGB.1, "深色模式绿色分量应更亮")
        XCTAssertGreaterThan(darkRGB.2, lightRGB.2, "深色模式蓝色分量应更亮")
    }

    /// 危险色同样在深色模式提亮
    func testDangerIsBrighterInDarkAppearance() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))

        let danger = DrawerTheme.adaptiveNSColor(light: 0xE0455F, dark: 0xF06C83)
        let lightRGB = try XCTUnwrap(rgb(danger, under: light))
        let darkRGB = try XCTUnwrap(rgb(danger, under: dark))
        XCTAssertGreaterThan(darkRGB.0, lightRGB.0)
        XCTAssertGreaterThan(darkRGB.1, lightRGB.1)
    }
}
