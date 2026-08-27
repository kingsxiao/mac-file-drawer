import Foundation

// MARK: - 持久化 v3：版本化容器
//
// v1：单个 items 数组（无分组）　v2：items 带 drawerID + drawers/current 两个独立 key
// v3：items/drawers/currentDrawerID 合入一个带版本号的容器，单 key 原子写——
// 三 key 分写存在崩溃窗口内的不一致（此前靠 init 守卫自愈）。旧布局只读迁移、
// 保留原 key 不删（用户回滚旧版仍能读到迁移时的快照）。

enum ShelfPersistence {
    static let storeKey = "com.wangxiao.filedrawer.store.v3"
    static let currentVersion = 3
    // 旧布局（v1/v2）key：仅作迁移读取源
    static let legacyItemsKey = "com.wangxiao.filedrawer.items"
    static let legacyDrawersKey = "com.wangxiao.filedrawer.drawers"
    static let legacyCurrentDrawerKey = "com.wangxiao.filedrawer.currentDrawer"

    struct Schema: Codable, Equatable {
        var version: Int
        var items: [ShelfItem]
        var drawers: [DrawerGroup]
        var currentDrawerID: UUID
    }

    // MARK: 读写

    /// 读 v3 容器；没有则从 v1/v2 旧布局迁移；都没有返回 nil（全新安装）
    static func load(defaults: UserDefaults) -> Schema? {
        if let data = defaults.data(forKey: storeKey),
           let schema = try? JSONDecoder().decode(Schema.self, from: data),
           schema.version == currentVersion {
            return schema
        }
        return legacyLoad(defaults: defaults)
    }

    /// 单 key 原子写
    static func save(_ schema: Schema, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(schema) else { return }
        defaults.set(data, forKey: storeKey)
    }

    // MARK: 旧布局迁移（v1/v2 → v3）

    /// 旧布局：itemsKey 的 [ShelfItem]（v1 无 drawerID / v2 有）+ drawersKey + currentDrawerKey。
    /// 迁移包含既有归一化：分组缺失建「默认」、条目 nil drawerID 归第一组、current 无效回落第一组。
    static func legacyLoad(defaults: UserDefaults) -> Schema? {
        // 完全没有旧数据 → nil
        guard defaults.data(forKey: legacyItemsKey) != nil else { return nil }

        var items: [ShelfItem] = []
        if let data = defaults.data(forKey: legacyItemsKey),
           let saved = try? JSONDecoder().decode([ShelfItem].self, from: data) {
            items = saved
        }

        var drawers: [DrawerGroup] = []
        if let data = defaults.data(forKey: legacyDrawersKey),
           let saved = try? JSONDecoder().decode([DrawerGroup].self, from: data),
           !saved.isEmpty {
            drawers = saved
        } else {
            drawers = [DrawerGroup(name: ShelfStore.defaultDrawerName)]
        }

        var current = drawers[0].id
        if let raw = defaults.string(forKey: legacyCurrentDrawerKey),
           let id = UUID(uuidString: raw),
           drawers.contains(where: { $0.id == id }) {
            current = id
        }

        let fallback = drawers[0].id
        for index in items.indices where items[index].drawerID == nil {
            items[index].drawerID = fallback
        }

        return Schema(version: currentVersion, items: items, drawers: drawers, currentDrawerID: current)
    }
}
