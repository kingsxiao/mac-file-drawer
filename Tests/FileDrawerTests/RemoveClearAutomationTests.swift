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
            // 未知分组名：拒绝执行，绝不能误清当前分组
            XCTAssertEqual(DrawerCommands.clearGroup("拼错的分组名-\(UUID())"), 0)
            XCTAssertNotNil(store.undoSnapshot, "清空也走可还原路径")
            XCTAssertEqual(store.undoLastRemoval(), 2)
        }
    }

    /// 分组归属（替身 helper，绕开 private resolvedDrawerID）
    private func resolved(_ item: ShelfItem, _ groupID: UUID) -> Bool {
        item.drawerID == groupID
    }

    // MARK: - 置顶 / 置前（批次35）

    func testURLPinAndSendToFrontParsing() {
        XCTAssertEqual(action("filedrawer://pin"), .pin(group: nil, limit: 0))
        XCTAssertEqual(action("filedrawer://pin?group=工作&limit=3"), .pin(group: "工作", limit: 3))
        XCTAssertEqual(action("filedrawer://unpin?limit=2"), .unpin(group: nil, limit: 2))
        XCTAssertEqual(action("filedrawer://pin?limit=-1"), .pin(group: nil, limit: 0))
        XCTAssertEqual(action("filedrawer://send-to-front"), .sendToFront(group: nil, limit: 0))
        XCTAssertEqual(
            action("filedrawer://send-to-front?group=下载&limit=5"),
            .sendToFront(group: "下载", limit: 5)
        )
    }

    func testPinAndSendToFrontSemantics() throws {
        let (store, groupID, dir) = try stageGroup(["甲.txt", "乙.txt", "丙.txt"])
        try MainActor.assumeIsolated {
            defer { try? FileManager.default.removeItem(at: dir) }
            let groupName = store.drawers.first { $0.id == groupID }!.name

            // 置顶最新 2 条（甲、乙）
            XCTAssertEqual(DrawerCommands.setPinned(group: groupName, limit: 2, pinned: true), 2)
            let groupItems = store.items(in: groupID)
            XCTAssertTrue(groupItems.first { $0.name == "甲.txt" }!.pinned)
            XCTAssertTrue(groupItems.first { $0.name == "乙.txt" }!.pinned)
            XCTAssertFalse(groupItems.first { $0.name == "丙.txt" }!.pinned)

            // 取消全部置顶
            XCTAssertEqual(DrawerCommands.setPinned(group: groupName, pinned: false), 3)
            XCTAssertTrue(store.items(in: groupID).allSatisfy { !$0.pinned })

            // 置前最新 1 条（甲）→ items 数组前部 + 该分组切手动顺序
            let moved = DrawerCommands.sendToFront(group: groupName, limit: 1)
            XCTAssertEqual(moved, 1)
            XCTAssertEqual(store.items.first?.name, "甲.txt", "整批移到 items 最前")
            XCTAssertEqual(
                InteractionModel.shared.sortMode(for: groupID),
                .manual,
                "置前应把该分组切到手动顺序（重排可见）"
            )

            // 空分组 / 未知分组
            XCTAssertEqual(DrawerCommands.sendToFront(group: "不存在的分组名"), 0)
            XCTAssertEqual(DrawerCommands.setPinned(group: "不存在的分组名", pinned: true), 0)
        }
    }

    // MARK: - 移动 / 重命名（批次36）

    func testURLMoveAndRenameParsing() {
        XCTAssertEqual(
            action("filedrawer://move?to=归档"),
            .move(group: nil, to: "归档", limit: 0)
        )
        XCTAssertEqual(
            action("filedrawer://move?group=下载&to=归档&limit=2"),
            .move(group: "下载", to: "归档", limit: 2)
        )
        XCTAssertEqual(action("filedrawer://move?to=%20"), .move(group: nil, to: nil, limit: 0), "空白目标视为未指定")
        XCTAssertEqual(
            action("filedrawer://rename?path=/tmp/a.txt&name=b.txt"),
            .rename(path: "/tmp/a.txt", newName: "b.txt")
        )
        XCTAssertNil(action("filedrawer://rename?path=/tmp/a.txt"), "rename 缺 name 参数")
    }

    func testMoveAndRenameSemantics() throws {
        let (store, groupID, dir) = try stageGroup(["甲.txt", "乙.txt", "丙.txt"])
        try MainActor.assumeIsolated {
            defer { try? FileManager.default.removeItem(at: dir) }
            let groupName = store.drawers.first { $0.id == groupID }!.name
            let currentBefore = store.currentDrawerID

            // 目标分组不存在 → 创建且不切换当前视图；limit 取最新 2 条（甲、乙）
            let drawersBefore = store.drawers.count
            XCTAssertEqual(DrawerCommands.moveItems(group: groupName, to: "归档-\(UUID().uuidString.prefix(4))", limit: 2), 2)
            XCTAssertEqual(store.currentDrawerID, currentBefore, "自动化建目标分组不应切换当前视图")
            XCTAssertEqual(store.items(in: groupID).count, 1)
            XCTAssertEqual(store.drawers.count, drawersBefore + 1, "目标分组不存在时应新建")

            // 源=目标 → 无操作
            let targetName = store.drawers.last { $0.id != groupID }!.name
            XCTAssertEqual(DrawerCommands.moveItems(group: groupName, to: groupName), 0)

            // 重命名：按路径命中（磁盘文件同步改名）
            let item = store.items(in: groupID).first!
            XCTAssertTrue(DrawerCommands.renameItem(path: item.path, to: "改名后.txt"))
            XCTAssertEqual(store.items(in: groupID).first?.name, "改名后.txt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("改名后.txt").path))
            // 路径未命中 → false
            XCTAssertFalse(DrawerCommands.renameItem(path: "/tmp/绝不存在的路径-\(UUID()).txt", to: "x.txt"))
        }
    }

}
