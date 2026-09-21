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

    /// 符号立体渐变的两端色（上亮下深）：在明暗两模式的瓷片底上都不得跌破可读下限。
    /// 渐变让符号有体积感，但跨度受 FileIconStyle.gradientToneSpread 约束，
    /// 最亮端（通常在对比度不利方向）也要保有大部分对比度。
    func testSymbolGradientEndpointsStayNearThreshold() {
        var failures: [String] = []
        for (name, style) in FileTypeCatalog.allStyles {
            for dark in [false, true] {
                let base = TypeColorContrast.tileBase(colorHex: style.colorHex, dark: dark)
                let (top, bottom) = style.symbolGradientHexes(dark: dark)
                let topRatio = TypeColorContrast.contrastRatio(top, base)
                let bottomRatio = TypeColorContrast.contrastRatio(bottom, base)
                let floor = TypeColorContrast.gradientEndpointFloor
                if topRatio < floor - 0.001 || bottomRatio < floor - 0.001 {
                    failures.append("\(name) dark=\(dark) top=\(String(format: "%.2f", topRatio)) bottom=\(String(format: "%.2f", bottomRatio))")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "渐变端点未达下限的类型色：\n\(failures.joined(separator: "\n"))")
    }

    /// 预览样本：去重保序、两组比值均达标（设置面板展示与该函数同源）
    func testPreviewSamplesDedupedAndCompliant() {
        let hexes: [UInt32] = [0x6C5CE7, 0x6C5CE7, 0x2FA252, 0xE0455F]
        let samples = TypeColorContrast.previewSamples(from: hexes)
        XCTAssertEqual(samples.map(\.hex), [0x6C5CE7, 0x2FA252, 0xE0455F], "去重保序")
        for sample in samples {
            XCTAssertGreaterThanOrEqual(sample.lightRatio, 3.0 - 0.001)
            XCTAssertGreaterThanOrEqual(sample.darkRatio, 3.0 - 0.001)
            XCTAssertGreaterThan(sample.lightRatio, 0)
            XCTAssertGreaterThan(sample.darkRatio, 0)
        }
        // 全目录家族色同样达标（面板展示的完整性前提）
        let all = TypeColorContrast.previewSamples(
            from: FileTypeCatalog.allStyles.map { $0.1.colorHex }
        )
        XCTAssertGreaterThan(all.count, 20, "家族色应聚出可观的样本数")
        XCTAssertTrue(all.allSatisfy { $0.lightRatio >= 3.0 - 0.001 && $0.darkRatio >= 3.0 - 0.001 })
    }

    // MARK: - 渐变徽章文字墨色（WCAG AA 4.5:1）

    /// 文字门槛（AA）：与瓷片符号的图形门槛 3:1 区分
    private static let textThreshold = 4.5

    /// 渐变徽章（撤销「还原」/ 头部「已选 N」等）的墨色在明暗两模式、
    /// 渐变两端上都 ≥4.5:1。此前体系只保瓷片符号 3:1，渐变徽章文字无校验——
    /// 调亮渐变端色时白字/墨字会悄悄跌破 AA（历史值：白 on 深档品牌渐变 2.51–3.24）。
    /// 规格来自 DrawerTheme.badgeInkSpecs（与色值定义同源，改色即改契约）
    func testBadgeInkMeetsAAThresholdInBothModes() {
        var failures: [String] = []
        for spec in DrawerTheme.badgeInkSpecs {
            for end in spec.ends {
                let ratio = TypeColorContrast.contrastRatio(spec.ink, end)
                if ratio < Self.textThreshold - 0.001 {
                    failures.append(
                        "\(spec.name)：墨色 \(String(format: "#%06X", spec.ink)) "
                            + "on \(String(format: "#%06X", end)) = \(String(format: "%.2f", ratio))"
                    )
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "渐变徽章墨色未达 AA 4.5:1：\n\(failures.joined(separator: "\n"))")
    }

    /// 选中青瓷直接作前景文字（头部搜索匹配计数）对典型材质底 ≥4.5:1
    func testSelectionTextMeetsAAThresholdOnMaterialBases() {
        var failures: [String] = []
        for spec in DrawerTheme.selectionTextSpecs {
            for base in spec.ends {
                let ratio = TypeColorContrast.contrastRatio(spec.ink, base)
                if ratio < Self.textThreshold - 0.001 {
                    failures.append(
                        "\(spec.name)：\(String(format: "%.2f", ratio))"
                    )
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "匹配计数青瓷字未达 AA 4.5:1：\(failures.joined(separator: "，"))")
    }

    /// PDF 瓷片色必须与危险色拉开（失效警示红 ≠ PDF 红，避免语义误读）：
    /// 色相距离 ≥15° 或明度差足够。新色自身仍受全目录 3:1 契约保护（上一测试）
    func testPDFTileColorSeparatesFromDanger() {
        func hue(_ hex: UInt32) -> Double {
            let c = TypeColorContrast.components(hex)
            let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
            guard mx > mn else { return 0 }
            let d = mx - mn
            var h: Double
            if mx == c.r { h = ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == c.g { h = (c.b - c.r) / d + 2 }
            else { h = (c.r - c.g) / d + 4 }
            h *= 60
            if h < 0 { h += 360 }
            return h
        }
        func lightness(_ hex: UInt32) -> Double {
            let c = TypeColorContrast.components(hex)
            return (max(c.r, c.g, c.b) + min(c.r, c.g, c.b)) / 2
        }

        let pdf = FileTypeCatalog.entries["pdf"]!.style.colorHex
        let danger: UInt32 = 0xE0455F // DrawerTheme.danger 浅色档（明暗两档同族色相）
        let rawDistance = abs(hue(pdf) - hue(danger))
        let bounded = min(rawDistance, 360 - rawDistance)
        let luminanceGap = abs(lightness(pdf) - lightness(danger))
        XCTAssertTrue(
            bounded >= 15 || luminanceGap >= 0.15,
            "PDF 色应与危险色拉开（色相差 \(bounded)°、明度差 \(luminanceGap)）"
        )
    }
}
