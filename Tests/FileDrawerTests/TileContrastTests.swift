import XCTest
@testable import FileDrawer

/// 瓷片对比度：WCAG 公式正确性 + 全部类型色在明暗两模式达到 ≥3:1（提亮后）
final class TileContrastTests: XCTestCase {

    // MARK: - 公式

    func testWCAGFormulaBasics() {
        XCTAssertEqual(TypeColorContrast.contrastRatio(0x000000, 0xFFFFFF), 21.0, accuracy: 0.01, "黑白应为 21:1")
        XCTAssertEqual(TypeColorContrast.contrastRatio(0x777777, 0x777777), 1.0, accuracy: 0.001, "同色应为 1:1")
        // 红/白已知比值 ≈ 3.998
        XCTAssertEqual(TypeColorContrast.contrastRatio(0xFF0000, 0xFFFFFF), 3.998, accuracy: 0.01)
    }

    func testBlendAndLighten() {
        // 50% 白叠黑 → 中灰
        XCTAssertEqual(TypeColorContrast.lighten(0x000000, mix: 0.5), 0x808080)
        // 不透明白叠任意 → 白
        XCTAssertEqual(TypeColorContrast.blend(fg: 0xFF0000, over: 0x00FF00, alpha: 1), 0xFF0000)
        XCTAssertEqual(TypeColorContrast.blend(fg: 0xFF0000, over: 0x00FF00, alpha: 0), 0x00FF00)
    }

    // MARK: - 提亮单调性与收敛

    func testEnsureContrastMonotonic() {
        let base = TypeColorContrast.darkBase
        let (color, mix) = TypeColorContrast.ensureContrast(symbol: 0x2E8B44, on: base)
        XCTAssertGreaterThanOrEqual(TypeColorContrast.contrastRatio(color, base), 3.0 - 0.0001)
        XCTAssertLessThanOrEqual(mix, TypeColorContrast.maxLightenMix + 0.0001)
        // 已达标色不提亮
        let (same, zeroMix) = TypeColorContrast.ensureContrast(symbol: 0xFFFFFF, on: base)
        XCTAssertEqual(same, 0xFFFFFF)
        XCTAssertEqual(zeroMix, 0)
    }

    // MARK: - 全类型色 × 明暗模式

    /// 目录里全部类型色（含文件夹与兜底）在两种模式下，提亮后都能达到 WCAG 图形阈值
    func testAllTypeColorsMeetThresholdInBothModes() {
        var failures: [String] = []
        for (name, style) in FileTypeCatalog.allStyles {
            for dark in [false, true] {
                let base = TypeColorContrast.tileBase(colorHex: style.colorHex, dark: dark)
                let ensured = TypeColorContrast.ensureContrast(symbol: style.colorHex, on: base)
                let ratio = TypeColorContrast.contrastRatio(ensured.color, base)
                if ratio < TypeColorContrast.threshold - 0.001 {
                    failures.append("\(name) dark=\(dark) ratio=\(String(format: "%.2f", ratio))")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "未达阈值的类型色：\(failures.joined(separator: "，"))")
    }

    /// 深色模式确有色被提亮（近似底色上中明度色普遍不足），且提亮保持色相（不超过上限）
    func testDarkModeLightensSomeColorsButBounded() {
        var lightened = 0
        for (_, style) in FileTypeCatalog.allStyles {
            let base = TypeColorContrast.tileBase(colorHex: style.colorHex, dark: true)
            let result = TypeColorContrast.ensureContrast(symbol: style.colorHex, on: base)
            if result.mix > 0 { lightened += 1 }
        }
        XCTAssertGreaterThan(lightened, 0, "深色模式应至少有一批类型色需要提亮")
        XCTAssertLessThan(lightened, FileTypeCatalog.allStyles.count, "但不应全部都被提亮（保留原色者）")
    }

    /// 亮底向黑加深：中亮色在浅瓷片上也能达标
    func testEnsureContrastDarkensOnLightBase() {
        let base = TypeColorContrast.lightBase
        let (color, mix) = TypeColorContrast.ensureContrast(symbol: 0x2FA252, on: base)
        XCTAssertGreaterThan(mix, 0, "浅底上的中亮绿需要加深")
        XCTAssertGreaterThanOrEqual(TypeColorContrast.contrastRatio(color, base), 3.0 - 0.0001)
        // 混合 50% 黑 → 深一半
        XCTAssertEqual(TypeColorContrast.darken(0xFFFFFF, mix: 0.5), 0x808080)
    }
}
