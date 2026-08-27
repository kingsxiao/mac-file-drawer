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
    static let collapsedTabSize = CGSize(width: 42, height: 190)

    static func expandedSize(visibleFrame: NSRect, settings: AppSettings) -> CGSize {
        let available = visibleFrame.height - margin * 2
        let height = max(minDrawerHeight, available * CGFloat(settings.drawerHeightRatio))
        return CGSize(width: CGFloat(settings.drawerWidth), height: height)
    }

    /// 展开态：贴右缘，按设置的垂直位置停靠
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
        return NSRect(
            x: visibleFrame.maxX - size.width,
            y: clampedY,
            width: size.width,
            height: size.height
        )
    }

    /// 收起态：窄边条贴右缘、垂直居中
    static func collapsedFrame(visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: visibleFrame.maxX - collapsedTabSize.width,
            y: visibleFrame.minY + (visibleFrame.height - collapsedTabSize.height) / 2,
            width: collapsedTabSize.width,
            height: collapsedTabSize.height
        )
    }

    /// 屏幕外（启动前 / 滑出后）
    static func offscreenFrame(visibleFrame: NSRect, settings: AppSettings) -> NSRect {
        var frame = expandedFrame(visibleFrame: visibleFrame, settings: settings)
        frame.origin.x = visibleFrame.maxX + 4
        return frame
    }
}
