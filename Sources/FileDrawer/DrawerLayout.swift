import AppKit

/// 抽屉窗口几何布局：以屏幕可视区 + 设置为输入的纯函数，便于单测。
@MainActor
enum DrawerLayout {
    static let minWidth: CGFloat = 280
    static let maxWidth: CGFloat = 420
    static let minRatio: Double = 0.5
    static let maxRatio: Double = 1.0
    /// 高度比例 = 1.0 时的上下呼吸边距
    static let margin: CGFloat = 24
    static let minDrawerHeight: CGFloat = 360
    static let collapsedTabSize = CGSize(width: 46, height: 196)
    /// 无屏（headless 启动 / 显示器全部断开）时的兜底可视区：
    /// 仅为让初始化完整走通（菜单栏图标、热键、屏幕变化监听先就位），
    /// 显示器接入后 didChangeScreenParameters 会立即重新定位。
    static let fallbackVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

    /// 目标屏幕：跟随鼠标时取指针所在屏（多显示器场景），
    /// 否则主屏；都拿不到时兜底任意一块屏。
    static func targetScreen(followMouse: Bool) -> NSScreen? {
        if followMouse {
            let mouse = NSEvent.mouseLocation
            if let hit = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
                return hit
            }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    static func expandedSize(visibleFrame: NSRect, settings: AppSettings) -> CGSize {
        let available = visibleFrame.height - margin * 2
        let height = max(minDrawerHeight, available * CGFloat(settings.drawerHeightRatio))
        return CGSize(width: CGFloat(settings.drawerWidth), height: height)
    }

    /// 展开态：按设置停靠左缘或右缘，垂直位置同样受设置控制
    static func expandedFrame(visibleFrame: NSRect, settings: AppSettings) -> NSRect {
        let size = expandedSize(visibleFrame: visibleFrame, settings: settings)
        let y: CGFloat
        switch settings.verticalAlignment {
        case .center: y = visibleFrame.minY + (visibleFrame.height - size.height) / 2
        case .top: y = visibleFrame.maxY - size.height
        case .bottom: y = visibleFrame.minY
        }
        // 抽屉高度下限可能超出小屏可视区：夹住不让 y 越界
        let clampedY = min(max(y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - size.height))
        let x = settings.edge == .right
            ? visibleFrame.maxX - size.width
            : visibleFrame.minX
        return NSRect(x: x, y: clampedY, width: size.width, height: size.height)
    }

    /// 收起态：窄边条贴停靠边缘、垂直居中
    static func collapsedFrame(visibleFrame: NSRect, settings: AppSettings) -> NSRect {
        let x = settings.edge == .right
            ? visibleFrame.maxX - collapsedTabSize.width
            : visibleFrame.minX
        return NSRect(
            x: x,
            y: visibleFrame.minY + (visibleFrame.height - collapsedTabSize.height) / 2,
            width: collapsedTabSize.width,
            height: collapsedTabSize.height
        )
    }

    /// 屏幕外（启动前 / 滑出后）：朝停靠侧完全滑出屏幕。
    /// 多显示器：停靠边外侧紧邻另一块屏时，滑出矩形会落在邻屏的可见区域上
    /// （表现为抽屉「从隔壁屏幕里飞出来」，隐藏停放时停在邻屏可见）——
    /// 此时退化为收起边条姿态作为出发 / 停放帧，与其他展开动画同构、永不跨屏。
    static func offscreenFrame(
        visibleFrame: NSRect,
        settings: AppSettings,
        otherScreenFrames: [NSRect] = []
    ) -> NSRect {
        var frame = expandedFrame(visibleFrame: visibleFrame, settings: settings)
        frame.origin.x = settings.edge == .right
            ? visibleFrame.maxX + 4
            : visibleFrame.minX - frame.width - 4
        if otherScreenFrames.contains(where: { frame.intersects($0) }) {
            frame = collapsedFrame(visibleFrame: visibleFrame, settings: settings)
        }
        return frame
    }

    /// 起止帧中心是否分属不同屏幕（跨屏定位应瞬移：位移动画会拖着窗口
    /// 横穿中间的屏幕，「飞过桌面」）。from 中心不在任何屏内（真滑出停放、
    /// 邻侧无屏）不算跨屏——朝同侧滑入只掠过目标屏自身边缘。
    static func crossesScreens(from: NSRect, to: NSRect, screenFrames: [NSRect]) -> Bool {
        func homeIndex(of rect: NSRect) -> Int? {
            screenFrames.firstIndex { $0.contains(NSPoint(x: rect.midX, y: rect.midY)) }
        }
        guard let origin = homeIndex(of: from) else { return false }
        guard let target = homeIndex(of: to) else { return true }
        return origin != target
    }
}
