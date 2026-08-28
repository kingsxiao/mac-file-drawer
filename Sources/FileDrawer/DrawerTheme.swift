import SwiftUI

// MARK: - 设计系统：品牌色与动效预设
// 全 app 统一从这里取用，保证视觉语言一致。
// 身份色是「靛紫」——刻意避开系统蓝，让抽屉一眼可辨。
// 品牌色按明暗外观自适应：深色模式整体提亮一档，保证在毛玻璃上的可读性。

enum DrawerTheme {
    /// 品牌强调色十六进制值（明 / 暗）：Color 与 NSColor 原体共用一套定义
    private static let accentLightHex: UInt32 = 0x6C5CE7
    private static let accentDarkHex: UInt32 = 0x8F7FF2

    /// 品牌强调色：靛紫（深色模式提亮）
    static let accent = adaptive(light: accentLightHex, dark: accentDarkHex)
    /// 强调色的 NSColor 原体。AttributedString 的 run 级前景色必须走 AppKit scope：
    /// SwiftUI scope 的 Color run 属性在实机 Text 渲染路径会被整体丢弃
    /// （离屏 ImageRenderer 却正常渲染，离线核验发现不了）——搜索高亮用之
    static var accentNSColor: NSColor {
        adaptiveNSColor(light: accentLightHex, dark: accentDarkHex)
    }
    /// 渐变端色：紫罗兰，用于指示条 / 徽章 / 图标底（深色模式提亮）
    static let accentAlt = adaptive(light: 0xA05CE6, dark: 0xB692F2)

    /// 品牌渐变（左上 → 右下）
    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentAlt],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    // 选中状态色：青瓷青。选中是高频长驻状态，与品牌靛紫刻意分开——
    // 冷色的青釉不与品牌色抢戏，明暗两种玻璃上也读得清爽。
    /// 选中主色：青碧（深色模式提亮）
    static let selection = adaptive(light: 0x0D9488, dark: 0x2DD4BF)
    /// 选中渐变端色：海青，用于前缘指示条 / 已选徽章
    static let selectionAlt = adaptive(light: 0x06B6D4, dark: 0x22D3EE)
    /// 选中色上的文字：亮外观填色深用白，暗外观填色浅用青墨
    static let selectionInk = adaptive(light: 0xFFFFFF, dark: 0x0B3430)

    /// 选中渐变（左上 → 右下），与品牌渐变同构
    static var selectionGradient: LinearGradient {
        LinearGradient(
            colors: [selection, selectionAlt],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// 危险色（清空 / 移除 / 失效提示；深色模式提亮）
    static let danger = adaptive(light: 0xE0455F, dark: 0xF06C83)

    /// 明暗自适应色：按当前绘制外观在两个色值间切换
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: adaptiveNSColor(light: light, dark: dark))
    }

    /// 自适应色的 NSColor 原体（测试按外观解析用）
    static func adaptiveNSColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let darkAppearances: [NSAppearance.Name] = [
                .darkAqua,
                .vibrantDark,
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastVibrantDark,
            ]
            let isDark = appearance.bestMatch(from: darkAppearances) != nil
            return NSColor(hex: isDark ? dark : light)
        }
    }
}

// MARK: - 十六进制 NSColor（供动态色 provider 使用）

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - 动效预设
// 全部是 Spring 或缓出，时长克制；按场景选型而不是各处随手写参数。

enum DrawerMotion {
    /// 利落、带一点回弹：按钮 / 徽章 / 行内反馈
    static let snap = Animation.spring(response: 0.3, dampingFraction: 0.75)
    /// 明显弹跳：入场强调、计数变化
    static let bouncy = Animation.spring(response: 0.38, dampingFraction: 0.62)
    /// 柔和：列表重排、面板级移动
    static let smooth = Animation.spring(response: 0.42, dampingFraction: 0.88)
    /// 快速淡入淡出
    static let fade = Animation.easeOut(duration: 0.16)
    /// 小控件悬停点亮：干脆、几乎无回弹（小图标上回弹会显得抖）
    static let iconHover = Animation.spring(response: 0.24, dampingFraction: 0.85)
}
