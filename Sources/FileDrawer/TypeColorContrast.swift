import SwiftUI

// MARK: - 瓷片类型色的对比度保障（WCAG）
//
// 瓷片符号色叠在「类型色 13%–30% 渐变 × 毛玻璃材质」上。材质随明暗与背景变化，
// 用「明/暗模式各自的典型底色」做可测近似：
//   浅色：超薄材质叠浅色壁纸 ≈ 0xF0F0F2
//   深色：超薄材质叠深色壁纸 ≈ 0x28282C
// 符号色（图形元素）按 WCAG ≥ 3:1 校验，不足时向白混合提亮（上限 45%，保住色相）。
// 全部纯函数，测试对全部类型色在两种模式下断言阈值。

enum TypeColorContrast {
    /// WCAG 图形对比度门槛
    static let threshold: Double = 3.0
    /// 提亮时向白混合的上限（再高就近似无色相了）
    static let maxLightenMix: Double = 0.45
    /// 浅色模式典型瓷片底色（材质近似）
    static let lightBase: UInt32 = 0xF0F0F2
    /// 深色模式典型瓷片底色（材质近似）
    static let darkBase: UInt32 = 0x28282C

    // MARK: RGB 分解 / 合成

    nonisolated static func components(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        (Double((hex >> 16) & 0xFF) / 255,
         Double((hex >> 8) & 0xFF) / 255,
         Double(hex & 0xFF) / 255)
    }

    nonisolated static func hex(r: Double, g: Double, b: Double) -> UInt32 {
        func channel(_ v: Double) -> UInt32 {
            UInt32(min(max(v, 0), 1) * 255 + 0.5)
        }
        return (channel(r) << 16) | (channel(g) << 8) | channel(b)
    }

    // MARK: WCAG 亮度 / 对比度

    nonisolated static func luminance(_ hex: UInt32) -> Double {
        let c = components(hex)
        func linear(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    nonisolated static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        let (lighter, darker) = la >= lb ? (la, lb) : (lb, la)
        return (lighter + 0.05) / (darker + 0.05)
    }

    // MARK: 混合

    /// 半透明前景叠在底色上（alpha 混合）
    nonisolated static func blend(fg: UInt32, over base: UInt32, alpha: Double) -> UInt32 {
        let f = components(fg), s = components(base)
        return hex(
            r: f.r * alpha + s.r * (1 - alpha),
            g: f.g * alpha + s.g * (1 - alpha),
            b: f.b * alpha + s.b * (1 - alpha)
        )
    }

    /// 向白混合提亮
    nonisolated static func lighten(_ hex: UInt32, mix: Double) -> UInt32 {
        blend(fg: 0xFFFFFF, over: hex, alpha: mix)
    }

    /// 向黑混合加深
    nonisolated static func darken(_ hex: UInt32, mix: Double) -> UInt32 {
        blend(fg: 0x000000, over: hex, alpha: mix)
    }

    // MARK: 对比度保障

    /// 瓷片底色近似：类型色按 20%（渐变中值）叠在模式底色上
    nonisolated static func tileBase(colorHex: UInt32, dark: Bool) -> UInt32 {
        blend(fg: colorHex, over: dark ? darkBase : lightBase, alpha: 0.20)
    }

    // MARK: 预览样本（设置面板「瓷片对比度」区）

    /// 一个类型色的明暗双模式预览：底色近似 + 调整后符号色 + 实测比值
    struct Sample: Identifiable, Equatable {
        let id: UInt32 // 即原色 hex
        let hex: UInt32
        let lightBase: UInt32
        let lightAdjusted: UInt32
        let lightRatio: Double
        let darkBase: UInt32
        let darkAdjusted: UInt32
        let darkRatio: Double
    }

    /// 一批类型色 → 去重保序的明暗预览样本（视图与测试共用）
    nonisolated static func previewSamples(from hexes: [UInt32]) -> [Sample] {
        var seen = Set<UInt32>()
        var samples: [Sample] = []
        for hex in hexes where seen.insert(hex).inserted {
            let lightBase = tileBase(colorHex: hex, dark: false)
            let light = ensureContrast(symbol: hex, on: lightBase)
            let darkBase = tileBase(colorHex: hex, dark: true)
            let dark = ensureContrast(symbol: hex, on: darkBase)
            samples.append(Sample(
                id: hex,
                hex: hex,
                lightBase: lightBase,
                lightAdjusted: light.color,
                lightRatio: contrastRatio(light.color, lightBase),
                darkBase: darkBase,
                darkAdjusted: dark.color,
                darkRatio: contrastRatio(dark.color, darkBase)
            ))
        }
        return samples
    }

    /// 保证符号色在瓷片底色上达到 WCAG 阈值：不足时按底色明暗定向调整——
    /// 暗底向白提亮、亮底向黑加深（步进 5%，封顶 maxLightenMix，保住色相）。
    /// 返回达标色（或尽力调整后的色）与实际混合量。
    @discardableResult
    nonisolated static func ensureContrast(
        symbol hex: UInt32,
        on base: UInt32,
        threshold: Double = threshold
    ) -> (color: UInt32, mix: Double) {
        if contrastRatio(hex, base) >= threshold {
            return (hex, 0)
        }
        let towardWhite = luminance(base) < 0.35
        var step = 0.05
        while step <= maxLightenMix + 0.0001 {
            let candidate = towardWhite ? lighten(hex, mix: step) : darken(hex, mix: step)
            if contrastRatio(candidate, base) >= threshold {
                return (candidate, step)
            }
            step += 0.05
        }
        let fallback = towardWhite
            ? lighten(hex, mix: maxLightenMix)
            : darken(hex, mix: maxLightenMix)
        return (fallback, maxLightenMix)
    }
}
