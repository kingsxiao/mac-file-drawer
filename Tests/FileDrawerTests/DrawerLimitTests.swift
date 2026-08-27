import XCTest
@testable import FileDrawer

/// 每组独立容量上限：分组各自淘汰、覆盖设置生效与回落
final class DrawerLimitTests: XCTestCase {

    private func items(_ count: Int, in drawerID: UUID, prefix: String) -> [ShelfItem] {
        (0..<count).map { idx in
            ShelfItem(
                url: URL(fileURLWithPath: "/tmp/\(prefix)-\(String(format: "%02d", idx)).txt"),
                addedAt: Date(timeIntervalSinceNow: -Double(idx) * 100),
                drawerID: drawerID
            )
        }
    }

    /// 分组 A 限 20（21 个淘汰最旧 1 个）；分组 B 不限（5 个全保留）；互不影响
    func testPerDrawerTrimEvictsWithinEachGroup() {
        let drawerA = UUID()
        let drawerB = UUID()
        let all = items(21, in: drawerA, prefix: "甲") + items(5, in: drawerB, prefix: "乙")

        let kept = ShelfStore.trimmedPerDrawer(all) { drawerID in
            drawerID == drawerA ? .m20 : .unlimited
        }
        let keptA = kept.filter { $0.drawerID == drawerA }
        let keptB = kept.filter { $0.drawerID == drawerB }
        XCTAssertEqual(keptA.count, 20)
        XCTAssertEqual(keptB.count, 5, "不限的分组不受其他分组上限影响")
        XCTAssertFalse(keptA.contains { $0.name.contains("甲-20") }, "A 组最旧的被淘汰")
        XCTAssertTrue(keptA.contains { $0.name.contains("甲-00") }, "A 组最新的保留")
    }

    /// 全局默认策略兜底：未设置覆盖的分组用全局值
    func testPerDrawerTrimFallsBackToDefault() {
        let drawerA = UUID()
        let drawerB = UUID()
        let all = items(25, in: drawerA, prefix: "甲") + items(25, in: drawerB, prefix: "乙")

        // 两个组都没有覆盖 → 都按 m20 淘汰到 20
        let kept = ShelfStore.trimmedPerDrawer(all) { _ in .m20 }
        XCTAssertEqual(kept.count, 40)
        XCTAssertEqual(kept.filter { $0.drawerID == drawerA }.count, 20)
        XCTAssertEqual(kept.filter { $0.drawerID == drawerB }.count, 20)
    }

    /// drawerID 为 nil 的异常条目共享一个兜底名额池，不混入其他分组
    func testNilDrawerItemsShareFallbackBucket() {
        let drawerA = UUID()
        var mixed = items(3, in: drawerA, prefix: "甲")
        mixed += (0..<22).map { idx in
            ShelfItem(
                url: URL(fileURLWithPath: "/tmp/无组-\(idx).txt"),
                addedAt: Date(timeIntervalSinceNow: -Double(idx) * 10)
            )
        }
        let kept = ShelfStore.trimmedPerDrawer(mixed) { drawerID in
            drawerID == ShelfStore.unassignedDrawerID ? .m20 : .unlimited
        }
        XCTAssertEqual(kept.filter { $0.drawerID == drawerA }.count, 3)
        XCTAssertEqual(kept.filter { $0.drawerID == nil }.count, 20)
    }

    /// 覆盖的设置与清除（setLimitOverride 立即触发收敛）
    func testLimitOverrideSetAndClear() {
        MainActor.assumeIsolated {
            let store = ShelfStore.shared
            let original = store.items
            let originalCurrent = store.currentDrawerID
            let originalDrawers = store.drawers
            let originalOverrides = store.drawers.filter { store.limitOverride(for: $0.id) != nil }.map(\.id)
            defer {
                store.items = original
                for id in originalOverrides { store.setLimitOverride(store.limitOverride(for: id), for: id) }
                for group in store.drawers where !originalDrawers.contains(where: { $0.id == group.id }) {
                    if store.drawers.count > 1 { _ = store.deleteDrawer(id: group.id) }
                }
                store.setLimitOverride(nil, for: originalCurrent)
                store.switchDrawer(to: originalCurrent)
            }

            let groupID = store.currentDrawerID
            store.items = items(25, in: groupID, prefix: "覆盖")
            store.setLimitOverride(.m20, for: groupID)
            XCTAssertEqual(store.limitOverride(for: groupID), .m20)
            XCTAssertEqual(store.items.count, 20, "设置覆盖后立即收敛到该上限")

            store.setLimitOverride(nil, for: groupID)
            XCTAssertNil(store.limitOverride(for: groupID), "nil 清除覆盖")
        }
    }
}
