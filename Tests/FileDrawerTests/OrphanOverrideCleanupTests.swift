import XCTest
@testable import FileDrawer

/// 分组删除时清理孤儿覆盖（容量上限 + 每组排序），防 UUID→策略映射永久累积
final class OrphanOverrideCleanupTests: XCTestCase {

    func testDeleteDrawerCleansUpOverrides() {
        MainActor.assumeIsolated {
            let store = ShelfStore.shared
            let model = InteractionModel.shared
            let originalItems = store.items
            let originalDrawers = store.drawers
            let originalCurrent = store.currentDrawerID
            defer {
                store.items = originalItems
                for group in store.drawers where !originalDrawers.contains(where: { $0.id == group.id }) {
                    if store.drawers.count > 1 { _ = store.deleteDrawer(id: group.id) }
                }
                store.switchDrawer(to: originalCurrent)
            }

            // 需要至少两个分组才能删
            guard let groupA = store.createDrawer(named: "清理甲\(UUID().uuidString.prefix(4))"),
                  store.createDrawer(named: "清理乙\(UUID().uuidString.prefix(4))") != nil else {
                return XCTFail("应能建两个分组")
            }

            store.setLimitOverride(.m20, for: groupA)
            model.setSortMode(.nameAscending, for: groupA)
            XCTAssertEqual(store.limitOverride(for: groupA), .m20)
            XCTAssertEqual(model.sortMode(for: groupA), .nameAscending)

            // 删除该分组 → 两类覆盖一并清理
            XCTAssertTrue(store.deleteDrawer(id: groupA))
            XCTAssertNil(store.limitOverride(for: groupA), "容量覆盖应清理")
            XCTAssertEqual(model.sortMode(for: groupA), model.defaultSortMode, "排序覆盖应回到默认")
        }
    }
}
