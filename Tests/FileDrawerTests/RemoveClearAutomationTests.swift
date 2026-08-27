import XCTest
@testable import FileDrawer

/// 移除 / 清空自动化：URL 解析与命令层语义（可还原）
final class RemoveClearAutomationTests: XCTestCase {

    // MARK: - URL 解析

    private func action(_ raw: String) -> URLRouter.Action? {
        URLRouter.action(for: URL(string: raw)!)
    }

    func testURLRemoveAndClearParsing() {
        XCTAssertEqual(action("filedrawer://remove"), .remove(group: nil, limit: 0))
        XCTAssertEqual(
            action("filedrawer://remove?group=工作&limit=3"),
            .remove(group: "工作", limit: 3)
        )
        XCTAssertEqual(action("filedrawer://remove?limit=-5"), .remove(group: nil, limit: 0), "负数按 0")
        XCTAssertEqual(action("filedrawer://remove?limit=abc"), .remove(group: nil, limit: 0), "非法数字按 0")
        XCTAssertEqual(action("filedrawer://clear"), .clear(group: nil))
        XCTAssertEqual(action("filedrawer://clear?group=%20%20"), .clear(group: nil), "空白分组视为未指定")
    }

    // MARK: - 命令层

    private func stageGroup(_ fileNames: [String]) throws -> (ShelfStore, UUID, URL) {
        try MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var items: [ShelfItem] = []
            for (idx, name) in fileNames.enumerated() {
                let url = dir.appendingPathComponent(name)
                try Data(name.utf8).write(to: url)
                items.append(ShelfItem(
                    url: url,
                    addedAt: Date(timeIntervalSinceNow: -Double(idx) * 100)
                ))
            }
            let store = ShelfStore.shared
            let original = store.items
            let originalDrawers = store.drawers
            let originalCurrent = store.currentDrawerID
            let groupName = "自动化-\(UUID().uuidString.prefix(6))"
            guard let groupID = store.createDrawer(named: groupName) else {
                throw NSError(domain: "test", code: 1)
            }
            store.items = items.map { item in
                var copy = item
                copy.drawerID = groupID
                return copy
            }
            let cleanup = {
                MainActor.assumeIsolated {
                    store.discardUndo()
                    store.items = original
                    for group in store.drawers
                    where !originalDrawers.contains(where: { $0.id == group.id }) {
                        if store.drawers.count > 1 { _ = store.deleteDrawer(id: group.id) }
                    }
                    store.switchDrawer(to: originalCurrent)
                }
            }
            addTeardownBlock(cleanup)
            return (store, groupID, dir)
        }
    }

    func testRemoveLimitTakesNewest() throws {
        let (store, groupID, dir) = try stageGroup(["甲.txt", "乙.txt", "丙.txt"])
        try MainActor.assumeIsolated {
            defer { try? FileManager.default.removeItem(at: dir) }
            let groupName = store.drawers.first { $0.id == groupID }!.name

            // createDrawer 会切到新组：当前分组即目标分组
            XCTAssertEqual(store.currentItems.count, 3)
            let removed = DrawerCommands.removeItems(group: groupName, limit: 2)
            XCTAssertEqual(removed, 2)
            XCTAssertEqual(store.currentItems.count, 1)
            // limit 取「最新」：甲（addedAt 最新）、乙被移除，剩最旧的丙
            let remaining = store.items.filter { resolved($0, groupID) }
            XCTAssertEqual(remaining.first?.name, "丙.txt")

            // 可整批还原
            let restored = store.undoLastRemoval()
            XCTAssertEqual(restored, 2)
        }
    }

    func testRemoveAllAndClearGroup() throws {
        let (store, groupID, dir) = try stageGroup(["甲.txt", "乙.txt"])
        try MainActor.assumeIsolated {
            defer { try? FileManager.default.removeItem(at: dir) }
            let groupName = store.drawers.first { $0.id == groupID }!.name

            // limit=0 全部移除
            XCTAssertEqual(DrawerCommands.removeItems(group: groupName), 2)
            XCTAssertEqual(store.items.filter { resolved($0, groupID) }.count, 0)
            _ = store.undoLastRemoval()

            // clear 指定分组
            XCTAssertEqual(DrawerCommands.clearGroup(groupName), 2)
            XCTAssertEqual(store.items.filter { resolved($0, groupID) }.count, 0)
            // 已清空的分组再清返回 0（且不覆盖上一条可还原快照）
            XCTAssertEqual(DrawerCommands.clearGroup(groupName), 0)
            XCTAssertNotNil(store.undoSnapshot, "清空也走可还原路径")
            XCTAssertEqual(store.undoLastRemoval(), 2)
        }
    }

    /// 分组归属（替身 helper，绕开 private resolvedDrawerID）
    private func resolved(_ item: ShelfItem, _ groupID: UUID) -> Bool {
        item.drawerID == groupID
    }
}
