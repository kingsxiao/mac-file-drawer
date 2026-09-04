import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 拖出多选：自定义 NSDraggingSession 拖拽源
//
// SwiftUI 的 onDrag 一次只能返回一个 NSItemProvider，拖不出「整批多选」。
// 这里在瓷片上叠一层轻量 NSView：仅在「该行属于选中集合」时参与命中测试，
// 鼠标拖动超过阈值后用 beginDraggingSession 把全部选中条目作为多个
// fileURL 粘贴板条目一次拖出（Finder / 邮件等目标端按多文件拷贝接收）。
// 非多选、单击、双击、右键、悬停等一切常规交互不受影响（视图隐藏时
// hitTest 直接忽略）。
//
// 拖出语义（调研里「复制 vs 移动」是高频诉求）：
// - 普通拖出 = 拷贝（默认，条目留在抽屉——暂存语义不变）；
// - 按住 ⌘ 拖到访达 = 移动：访达把源文件移走，会话结束后条目随之移除；
// - 拖到程序坞「废纸篓」= .delete：文件进废纸篓，条目移除；
// - 设置「拖出后移除条目」开启时，普通拷贝拖出也移除（可还原）。

/// 拖出会话结束后的条目处置（纯函数，可单测）
enum DragOutDisposition: Equatable {
    /// 条目留在抽屉（普通拷贝 / 会话取消 / 落在行内 = 排序）
    case keep
    /// 拷贝完成但开启了「拖出后移除」：走可还原移除（源文件仍在原位，Put Back 有效）
    case removeUndoable
    /// 目标端已把源文件移走（⌘拖拽移动 / 废纸篓）：静默移除（旧路径已失效，还原无意义）
    case removeSilently(trashed: Bool)
}

enum DragOutSupport {

    /// 会话结束操作 → 条目处置
    static func disposition(
        for operation: NSDragOperation,
        landedOnRow: Bool,
        removeOnCopy: Bool
    ) -> DragOutDisposition {
        // 落在抽屉内的行上 = 行内排序，不是拖出
        if landedOnRow { return .keep }
        if operation == .delete { return .removeSilently(trashed: true) }
        if operation == .move { return .removeSilently(trashed: false) }
        if operation.contains(.copy), removeOnCopy { return .removeUndoable }
        return .keep
    }

    /// 一批条目 → 拖拽粘贴板条目（每文件一条，fileURL + 名称）
    static func pasteboardItems(for items: [ShelfItem]) -> [NSPasteboardItem] {
        items.compactMap { item in
            guard FileManager.default.fileExists(atPath: item.path) else { return nil }
            let pbItem = NSPasteboardItem()
            pbItem.setString(item.url.absoluteString, forType: .fileURL)
            pbItem.setString(item.name, forType: .string)
            return pbItem
        }
    }

    /// 拖拽预览图：首个文件图标 + 右下角「×N」数量角标
    static func dragImage(for items: [ShelfItem]) -> NSImage {
        let side: CGFloat = 56
        let image = NSImage(size: NSSize(width: side, height: side))
        guard let first = items.first else { return image }
        image.lockFocus()
        let icon = NSWorkspace.shared.icon(forFile: first.path)
        icon.size = NSSize(width: side, height: side)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        if items.count > 1 {
            let badge = "×\(items.count)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let textSize = badge.size(withAttributes: attributes)
            let padding: CGFloat = 4
            let badgeRect = NSRect(
                x: side - textSize.width - padding * 2 - 1,
                y: 1,
                width: textSize.width + padding * 2,
                height: textSize.height + padding
            )
            let tint = NSColor(calibratedRed: 0.42, green: 0.36, blue: 0.9, alpha: 0.92)
            tint.setFill()
            badgeRect.fill()
            NSColor.controlBackgroundColor.setStroke()
            NSBezierPath(rect: badgeRect).stroke()
            badge.draw(
                in: NSRect(
                    x: badgeRect.minX + padding,
                    y: badgeRect.minY + padding / 2,
                    width: textSize.width,
                    height: textSize.height
                ),
                withAttributes: attributes
            )
        }
        image.unlockFocus()
        return image
    }
}

// MARK: - 拖拽源视图

/// 瓷片上的多选拖拽源：active=false 时隐藏（hitTest 忽略），不影响任何交互。
final class MultiDragSourceView: NSView, NSDraggingSource {
    /// 本次要整批拖出的条目（快照，拖出过程中列表可能变化）
    var dragTargets: [ShelfItem] = []
    /// 会话真正开始（越过阈值）后的回调（供「拖出后自动收起」与排序会话登记）
    var onSessionBegan: (() -> Void)?
    /// 会话结束（落下 / 取消）回调：拿到目标端实际执行的操作（.copy / .move / .delete…），
    /// 供「移走语义」决定条目去留。在主线程回调。
    var onSessionEnded: ((NSDragOperation) -> Void)?

    private var dragBegan = false
    private var initialPoint = NSPoint.zero

    override func mouseDown(with event: NSEvent) {
        initialPoint = convert(event.locationInWindow, from: nil)
        dragBegan = false
        // 不消费事件：让点击继续传递给 SwiftUI（选中 / 双击等行为保持原样）
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragBegan else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - initialPoint.x
        let dy = current.y - initialPoint.y
        guard dx * dx + dy * dy > 16 else { return } // 4pt 阈值
        guard !dragTargets.isEmpty else { return }

        let pbItems = DragOutSupport.pasteboardItems(for: dragTargets)
        guard !pbItems.isEmpty else { return }
        dragBegan = true

        let image = DragOutSupport.dragImage(for: dragTargets)
        let frame = NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        let draggingItems = pbItems.map { pbItem -> NSDraggingItem in
            let draggingItem = NSDraggingItem(pasteboardWriter: pbItem)
            draggingItem.draggingFrame = frame
            draggingItem.imageComponentsProvider = {
                let component = NSDraggingImageComponent(key: NSDraggingItem.ImageComponentKey("icon"))
                component.contents = image
                component.frame = frame
                return [component]
            }
            return draggingItem
        }

        beginDraggingSession(with: draggingItems, event: event, source: self)
        onSessionBegan?()
    }

    // MARK: NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // 声明 copy + move + delete：普通拖出 = 拷贝（条目留下，暂存语义）；
        // 访达里按住 ⌘ 松手 = 移动（访达移走源文件）；程序坞废纸篓 = delete。
        // 目标端始终自主决定执行哪种，这里只是把三种语义都摆上桌。
        [.copy, .move, .delete]
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        let callback = onSessionEnded
        DispatchQueue.main.async {
            callback?(operation)
        }
    }
}

// MARK: - SwiftUI 桥接

/// 瓷片上的多选拖拽层；active 时才可见/可命中。
struct MultiDragOverlay: NSViewRepresentable {
    let active: Bool
    let targets: [ShelfItem]
    var onSessionBegan: (() -> Void)? = nil
    var onSessionEnded: ((NSDragOperation) -> Void)? = nil

    func makeNSView(context: Context) -> MultiDragSourceView {
        let view = MultiDragSourceView()
        view.onSessionBegan = onSessionBegan
        view.onSessionEnded = onSessionEnded
        return view
    }

    func updateNSView(_ view: MultiDragSourceView, context: Context) {
        view.dragTargets = targets
        view.onSessionBegan = onSessionBegan
        view.onSessionEnded = onSessionEnded
        view.isHidden = !active
    }
}
