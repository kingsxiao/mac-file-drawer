import AppKit
import AppIntents
import SwiftUI

// MARK: - 抽屉命令层：URL Scheme 与 App Intents（快捷指令）共用的执行入口
//
// 把「放入 / 读取 / 展开收起」的业务从 AppDelegate 里抽出来，
// filedrawer:// URL 与 Shortcuts 的 App Intent 走同一条路径，行为永远一致。

@MainActor
enum DrawerCommands {

    /// 放入条目：过滤不存在路径，可指定分组（不存在则创建并切换）；返回 (新增, 重复跳过, 无效路径)
    @discardableResult
    static func add(paths: [String], group rawGroup: String? = nil) -> (added: Int, skippedDuplicates: Int, invalid: Int) {
        let store = ShelfStore.shared
        if let rawGroup, !rawGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.ensureDrawer(named: rawGroup)
        }
        let valid = paths.filter { FileManager.default.fileExists(atPath: $0) }
        let invalid = paths.count - valid.count
        guard !valid.isEmpty else { return (0, 0, invalid) }

        var added = 0
        var skipped = 0
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            let result = store.add(urls: valid.map { URL(fileURLWithPath: $0) })
            added = result.added
            skipped = result.skippedDuplicates
        }
        var notes: [String] = []
        if skipped > 0 { notes.append(L10n.tf("已跳过 %d 个重复条目", skipped)) }
        if invalid > 0 { notes.append(L10n.tf("%d 个路径不存在", invalid)) }
        if !notes.isEmpty { store.postNotice(notes.joined(separator: "，")) }
        DiagnosticsLog.shared.log("auto", "add added=\(added) skipped=\(skipped) invalid=\(invalid)")
        return (added, skipped, invalid)
    }

    /// 在访达中定位文件
    static func reveal(path: String) {
        DiagnosticsLog.shared.log("auto", "reveal")
        ShelfStore.shared.refreshMissingStatus()
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 读取条目：分组可选（nil=当前分组），按加入时间倒序，最多 limit 个，只含磁盘上仍存在的
    /// （先过滤存在性再截断，保证返回的是「最新的 limit 个存在的」而不是「前 limit 个里碰巧存在的」）
    static func list(group rawGroup: String? = nil, limit: Int = 50) -> [URL] {
        let store = ShelfStore.shared
        let drawerID: UUID
        if let rawGroup,
           !rawGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let hit = store.drawers.first(where: { $0.name == rawGroup }) {
            drawerID = hit.id
        } else {
            drawerID = store.currentDrawerID
        }
        return store.items(in: drawerID)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.addedAt > $1.addedAt }
            .prefix(max(0, limit))
            .map(\.url)
    }

    /// 解析分组名 → 分组 ID（nil / 未命中 = 当前分组）
    private static func drawerID(named rawGroup: String?) -> UUID? {
        let store = ShelfStore.shared
        guard let rawGroup,
              !rawGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return store.currentDrawerID
        }
        return store.drawers.first { $0.name == rawGroup }?.id
    }

    /// 移除条目：分组可选（默认当前），limit>0 只移最新 N 个（0=全部）；走可还原路径
    @discardableResult
    static func removeItems(group: String? = nil, limit: Int = 0) -> Int {
        let store = ShelfStore.shared
        guard let drawerID = drawerID(named: group) else { return 0 }
        let candidates = store.items(in: drawerID).sorted { $0.addedAt > $1.addedAt }
        let targets = limit > 0 ? Array(candidates.prefix(limit)) : Array(candidates)
        guard !targets.isEmpty else { return 0 }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
            store.remove(targets)
        }
        DiagnosticsLog.shared.log("auto", "remove group=\(group ?? "-") limit=\(limit) count=\(targets.count)")
        return targets.count
    }

    /// 清空分组（默认当前分组）；走可还原路径。返回清掉的条数。
    @discardableResult
    static func clearGroup(_ group: String? = nil) -> Int {
        let store = ShelfStore.shared
        // 指定了分组名但未命中时拒绝执行——绝不能误清当前正在看的分组
        guard let drawerID = drawerID(named: group) else { return 0 }
        // clear() 的作用域是当前分组：目标是其他分组时先切换
        if drawerID != store.currentDrawerID {
            store.switchDrawer(to: drawerID)
        }
        let before = store.currentItems.count
        store.clear()
        DiagnosticsLog.shared.log("auto", "clear group=\(group ?? "-") count=\(before)")
        return before
    }

    /// 置顶 / 取消置顶：分组可选（默认当前），limit>0 只作用于最新 N 条（0=全部）。返回受影响条数。
    @discardableResult
    static func setPinned(group: String? = nil, limit: Int = 0, pinned: Bool) -> Int {
        let store = ShelfStore.shared
        guard let drawerID = drawerID(named: group) else { return 0 }
        let candidates = store.items(in: drawerID).sorted { $0.addedAt > $1.addedAt }
        let targets = limit > 0 ? Array(candidates.prefix(limit)) : Array(candidates)
        guard !targets.isEmpty else { return 0 }
        store.setPinned(pinned, for: Set(targets.map(\.id)))
        DiagnosticsLog.shared.log("auto", "pin=\(pinned) group=\(group ?? "-") limit=\(limit) count=\(targets.count)")
        return targets.count
    }

    /// 移到最前：分组可选（默认当前），limit>0 只移动最新 N 条（0=全部）；
    /// 自动把该分组切到「手动顺序」，重排在界面上立即可见。返回移动条数。
    @discardableResult
    static func sendToFront(group: String? = nil, limit: Int = 0) -> Int {
        let store = ShelfStore.shared
        guard let drawerID = drawerID(named: group) else { return 0 }
        let candidates = store.items(in: drawerID).sorted { $0.addedAt > $1.addedAt }
        let targets = limit > 0 ? Array(candidates.prefix(limit)) : Array(candidates)
        guard !targets.isEmpty else { return 0 }
        InteractionModel.shared.setSortMode(.manual, for: drawerID)
        store.send(ids: targets.map(\.id), toFront: true)
        DiagnosticsLog.shared.log("auto", "send-to-front group=\(group ?? "-") limit=\(limit) count=\(targets.count)")
        return targets.count
    }

    /// 条目整批移到目标分组：源分组可选（默认当前），limit>0 只移最新 N 条（0=全部）；
    /// 目标分组不存在则创建（不切换当前视图）。源=目标视为无操作。返回移动条数。
    @discardableResult
    static func moveItems(group: String? = nil, to target: String?, limit: Int = 0) -> Int {
        let store = ShelfStore.shared
        guard let drawerID = drawerID(named: group) else { return 0 }
        guard let targetName = target?.trimmingCharacters(in: .whitespacesAndNewlines),
              !targetName.isEmpty else { return 0 }

        let targetID: UUID
        if let hit = store.drawers.first(where: { $0.name == targetName }) {
            targetID = hit.id
        } else if let created = store.createDrawer(named: targetName, switchTo: false) {
            targetID = created
        } else {
            return 0
        }
        guard targetID != drawerID else { return 0 }

        let candidates = store.items(in: drawerID).sorted { $0.addedAt > $1.addedAt }
        let targets = limit > 0 ? Array(candidates.prefix(limit)) : Array(candidates)
        guard !targets.isEmpty else { return 0 }
        store.moveItems(ids: targets.map(\.id), to: targetID)
        DiagnosticsLog.shared.log("auto", "move group=\(group ?? "-") count=\(targets.count)")
        return targets.count
    }

    /// 按文件路径重命名条目（同目录改名；同名自动序号）。路径未命中返回 false。
    @discardableResult
    static func renameItem(path: String, to newName: String) -> Bool {
        let store = ShelfStore.shared
        let standardized = (path as NSString).standardizingPath
        guard let item = store.items.first(where: { $0.path == standardized }) else {
            DiagnosticsLog.shared.log("auto", "rename miss")
            return false
        }
        let ok = store.rename(id: item.id, to: newName)
        DiagnosticsLog.shared.log("auto", "rename ok=\(ok)")
        return ok
    }

    /// 展开 / 收起 / 切换
    static func setExpansion(expand: Bool?) {
        // NSApp 在单元测试进程里可能为 nil（IUO 解包会崩）——先安全解包
        guard let app = NSApp as NSApplication?, let delegate = app.delegate as? AppDelegate else { return }
        switch expand {
        case .none: delegate.toggleCollapseOrExpand()
        case .some(true): delegate.expandDrawer()
        case .some(false): delegate.collapseDrawer()
        }
    }
}
