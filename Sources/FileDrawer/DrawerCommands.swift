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
        return (added, skipped, invalid)
    }

    /// 在访达中定位文件
    static func reveal(path: String) {
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
        return targets.count
    }

    /// 清空分组（默认当前分组）；走可还原路径。返回清掉的条数。
    @discardableResult
    static func clearGroup(_ group: String? = nil) -> Int {
        let store = ShelfStore.shared
        // clear() 的作用域是当前分组：目标是其他分组时先切换
        if let drawerID = drawerID(named: group), drawerID != store.currentDrawerID {
            store.switchDrawer(to: drawerID)
        }
        let before = store.currentItems.count
        store.clear()
        return before
    }

    /// 展开 / 收起 / 切换
    static func setExpansion(expand: Bool?) {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        switch expand {
        case .none: delegate.toggleCollapseOrExpand()
        case .some(true): delegate.expandDrawer()
        case .some(false): delegate.collapseDrawer()
        }
    }
}
