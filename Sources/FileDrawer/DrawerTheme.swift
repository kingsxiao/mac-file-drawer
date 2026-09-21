import AppKit
import SwiftUI

// MARK: - 设计系统：品牌色与动效预设
// 全 app 统一从这里取用，保证视觉语言一致。
// 身份色是「靛紫」——刻意避开系统蓝，让抽屉一眼可辨。
// 品牌色按明暗外观自适应：深色模式整体提亮一档，保证在毛玻璃上的可读性。

enum DrawerTheme {
    /// 品牌强调色十六进制值（明 / 暗）：Color 与 NSColor 原体共用一套定义
    private static let accentLightHex: UInt32 = 0x6C5CE7
    private static let accentDarkHex: UInt32 = 0x8F7FF2
    /// 渐变端色（明 / 暗）：紫罗兰，用于指示条 / 徽章 / 图标底。
    /// 浅色档压深一档（0xA05CE6→0x8A4ED8）：品牌渐变上有白字徽章（撤销「还原」、
    /// 置顶角标），端色提亮会让白字跌破 WCAG AA 4.5:1（压深后两端 4.86/5.05，
    /// 契约测试锁定）
    private static let accentAltLightHex: UInt32 = 0x8A4ED8
    private static let accentAltDarkHex: UInt32 = 0xB692F2
    /// 品牌渐变上的文字墨色（明 / 暗）：浅色档渐变够深用白；深色档渐变整体
    /// 提亮，白字只有 2.51–3.24:1，改深靛墨（复用 selectionInk 深青墨的
    /// 「近黑带色相」既有模式；两端 5.32/6.88，契约测试锁定）
    private static let accentInkLightHex: UInt32 = 0xFFFFFF
    private static let accentInkDarkHex: UInt32 = 0x1B1245

    // 选中状态色：青瓷青。选中是高频长驻状态，与品牌靛紫刻意分开——
    // 冷色的青釉不与品牌色抢戏，明暗两种玻璃上也读得清爽。
    /// 选中主色（明 / 暗）：青碧（深色模式提亮）。浅色档压深一档
    /// （0x0D9488→0x0F766E）：它同时是「已选 N」徽章底渐变端与搜索匹配计数的
    /// 青瓷文字色，原值作文字只有 3.29:1，压深后 4.81:1（AA）
    private static let selectionLightHex: UInt32 = 0x0F766E
    private static let selectionDarkHex: UInt32 = 0x2DD4BF
    /// 选中渐变端色（明 / 暗）：海青，用于前缘指示条 / 已选徽章。浅色档压深
    /// 一档（0x06B6D4→0x0E7490）：让「已选 N」白字在渐变两端都 ≥4.5:1（5.47/5.36）
    private static let selectionAltLightHex: UInt32 = 0x0E7490
    private static let selectionAltDarkHex: UInt32 = 0x22D3EE
    /// 选中色上的文字（明 / 暗）：亮外观填色深用白，暗外观填色浅用青墨
    private static let selectionInkLightHex: UInt32 = 0xFFFFFF
    private static let selectionInkDarkHex: UInt32 = 0x0B3430

    /// 品牌强调色：靛紫（深色模式提亮）
    static let accent = adaptive(light: accentLightHex, dark: accentDarkHex)
    /// 强调色的 NSColor 原体。AttributedString 的 run 级前景色必须走 AppKit scope：
    /// SwiftUI scope 的 Color run 属性在实机 Text 渲染路径会被整体丢弃
    /// （离屏 ImageRenderer 却正常渲染，离线核验发现不了）——搜索高亮用之
    static var accentNSColor: NSColor {
        adaptiveNSColor(light: accentLightHex, dark: accentDarkHex)
    }
    /// 渐变端色：紫罗兰（见 accentAltLightHex 注释）
    static let accentAlt = adaptive(light: accentAltLightHex, dark: accentAltDarkHex)
    /// 品牌渐变上的文字墨色（见 accentInkLightHex 注释）
    static let accentInk = adaptive(light: accentInkLightHex, dark: accentInkDarkHex)

    /// 品牌渐变（左上 → 右下）
    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentAlt],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// 选中主色：青碧（见 selectionLightHex 注释）
    static let selection = adaptive(light: selectionLightHex, dark: selectionDarkHex)
    /// 选中渐变端色：海青（见 selectionAltLightHex 注释）
    static let selectionAlt = adaptive(light: selectionAltLightHex, dark: selectionAltDarkHex)
    /// 选中色上的文字：亮外观填色深用白，暗外观填色浅用青墨
    static let selectionInk = adaptive(light: selectionInkLightHex, dark: selectionInkDarkHex)

    /// 选中渐变（左上 → 右下），与品牌渐变同构
    static var selectionGradient: LinearGradient {
        LinearGradient(
            colors: [selection, selectionAlt],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// 危险色（清空 / 移除 / 失效提示；深色模式提亮）
    static let danger = adaptive(light: 0xE0455F, dark: 0xF06C83)

    // MARK: 渐变徽章墨色契约（测试对账用）
    //
    // 品牌渐变 / 选中渐变上会放小号文字（撤销 toast 的「还原」、头部「已选 N」），
    // 文字可读性与瓷片符号的 3:1 契约同源但门槛更高（WCAG AA 文字 4.5:1）。
    // 这里把「渐变端色 + 配套墨色」按明暗模式整理成单一事实源，测试遍历断言——
    // 防止后续调亮渐变时墨色悄悄失效（根因正是此前只有瓷片符号有校验）。

    /// 一枚渐变徽章的可读性规格：渐变两端色 + 配套墨色
    struct BadgeInkSpec {
        let name: String
        let ends: [UInt32]
        let ink: UInt32
    }

    /// 全部渐变徽章的墨色规格（明 / 暗模式各自成立）
    static var badgeInkSpecs: [BadgeInkSpec] {
        [
            BadgeInkSpec(
                name: "品牌渐变 × accentInk（浅色）",
                ends: [accentLightHex, accentAltLightHex],
                ink: accentInkLightHex
            ),
            BadgeInkSpec(
                name: "品牌渐变 × accentInk（深色）",
                ends: [accentDarkHex, accentAltDarkHex],
                ink: accentInkDarkHex
            ),
            BadgeInkSpec(
                name: "选中渐变 × selectionInk（浅色）",
                ends: [selectionLightHex, selectionAltLightHex],
                ink: selectionInkLightHex
            ),
            BadgeInkSpec(
                name: "选中渐变 × selectionInk（深色）",
                ends: [selectionDarkHex, selectionAltDarkHex],
                ink: selectionInkDarkHex
            ),
        ]
    }

    /// 选中主色直接作前景文字（搜索匹配计数）时的规格：对明暗模式典型材质底断言
    static var selectionTextSpecs: [BadgeInkSpec] {
        [
            BadgeInkSpec(
                name: "匹配计数青瓷字（浅色材质底）",
                ends: [TypeColorContrast.lightBase],
                ink: selectionLightHex
            ),
            BadgeInkSpec(
                name: "匹配计数青瓷字（深色材质底）",
                ends: [TypeColorContrast.darkBase],
                ink: selectionDarkHex
            ),
        ]
    }

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
    /// 系统「减少动态」（辅助功能）开关：NSWorkspace 直答而非 SwiftUI @Environment——
    /// 模型层（ShelfModel 等非视图上下文）的 withAnimation 也取得到同一判断；
    /// 每次 withAnimation 求值时读取，设置变化无需通知监听即可生效
    static var reduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 预设全部是计算属性：减弱档退为「无过冲 easeOut」（HIG：去掉回弹与弹跳，
    /// 保留到位时长），正常档维持既有弹簧手感——一处定义覆盖视图层与模型层
    /// 的全部调用点。

    /// 利落、带一点回弹：按钮 / 徽章 / 行内反馈
    static var snap: Animation {
        reduceMotionEnabled ? .easeOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 0.75)
    }
    /// 明显弹跳：入场强调、计数变化
    static var bouncy: Animation {
        reduceMotionEnabled ? .easeOut(duration: 0.24) : .spring(response: 0.38, dampingFraction: 0.62)
    }
    /// 柔和：列表重排、面板级移动
    static var smooth: Animation {
        reduceMotionEnabled ? .easeOut(duration: 0.28) : .spring(response: 0.42, dampingFraction: 0.88)
    }
    /// 快速淡入淡出（≤0.2s 的手写 easeOut 一律收编到这里，改时长只动一处）
    static var fade: Animation {
        .easeOut(duration: 0.16)
    }
    /// 小控件悬停点亮：干脆、几乎无回弹（小图标上回弹会显得抖）
    static var iconHover: Animation {
        reduceMotionEnabled ? .easeOut(duration: 0.15) : .spring(response: 0.24, dampingFraction: 0.85)
    }
    /// 抽屉展开 / 收起 / 边条弹出（壳层）：与窗口弹簧 WindowSpringAnimator 的
    /// 默认参数（stiffness 210 / damping 22，阻尼比 ≈ 0.76、过冲 ≈ 2.7%）互为
    /// 配套基准——壳（窗口 frame）与内容（ SwiftUI 视图）两侧同量级回弹，
    /// 调任一侧时同步另一侧
    static var expand: Animation {
        reduceMotionEnabled ? .easeOut(duration: 0.26) : .spring(response: 0.4, dampingFraction: 0.9)
    }
    /// 条目增删 / 历史条目删除 / 搜索面板切换等内容变化：0.3–0.32 / 0.8–0.82
    /// 的近亲参数归一（原 11 处手写落此）
    static var listChange: Animation {
        reduceMotionEnabled ? .easeOut(duration: 0.22) : .spring(response: 0.32, dampingFraction: 0.8)
    }
}
