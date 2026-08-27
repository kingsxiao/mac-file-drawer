import SwiftUI

// MARK: - 设计系统：品牌色与动效预设
// 全 app 统一从这里取用，保证视觉语言一致。
// 身份色是「靛紫」——刻意避开系统蓝，让抽屉一眼可辨。

enum DrawerTheme {
    /// 品牌强调色：靛紫
    static let accent = Color(hex: 0x6C5CE7)
    /// 渐变端色：紫罗兰，用于指示条 / 徽章 / 图标底
    static let accentAlt = Color(hex: 0xA05CE6)

    /// 品牌渐变（左上 → 右下）
    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentAlt],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// 危险色（清空 / 移除）
    static let danger = Color(hex: 0xE0455F)
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
}
