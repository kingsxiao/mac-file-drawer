import XCTest
@testable import FileDrawer

/// 共享命令层：放入（含分组创建）/ 读取 / ensureDrawer
final class DrawerCommandsTests: XCTestCase {

    func testAddCreatesGroupAndReturnsCounts() throws {
        try MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let store = ShelfStore.shared
            let original = store.items
            let originalDrawers = store.drawers
            let originalCurrent = store.currentDrawerID
            defer {
                store.items = original
                for group in store.drawers where !originalDrawers.contains(where: { $0.id == group.id }) {
                    if store.drawers.count > 1 { _ = store.deleteDrawer(id: group.id) }
                }
                store.switchDrawer(to: originalCurrent)
            }

            let file = dir.appendingPathComponent("甲.txt")
            try Data("a".utf8).write(to: file)
            let groupName = "命令层-\(UUID().uuidString.prefix(6))"

            let first = DrawerCommands.add(paths: [file.path], group: groupName)
            XCTAssertEqual(first.added, 1)
            XCTAssertEqual(first.invalid, 0)
            XCTAssertEqual(store.currentDrawerName, groupName, "分组不存在时创建并切换")
            XCTAssertEqual(store.currentItems.map(\.name), ["甲.txt"])

            // 重复放入同一文件：跳过计数
            let second = DrawerCommands.add(paths: [file.path, dir.appendingPathComponent("不存在.txt").path], group: groupName)
            XCTAssertEqual(second.added, 0)
            XCTAssertEqual(second.skippedDuplicates, 1)
            XCTAssertEqual(second.invalid, 1)

            // 全部无效：0 新增
            let third = DrawerCommands.add(paths: ["/tmp/绝对不存在-\(UUID()).txt"])
            XCTAssertEqual(third.added, 0)
            XCTAssertEqual(third.invalid, 1)
        }
    }

    /// 读取：当前分组 / 指定分组 / 数量上限 / 只含存在文件
    func testListScopesAndLimit() throws {
        try MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let store = ShelfStore.shared
            let original = store.items
            let originalDrawers = store.drawers
            let originalCurrent = store.currentDrawerID
            defer {
                store.items = original
                for group in store.drawers where !originalDrawers.contains(where: { $0.id == group.id }) {
                    if store.drawers.count > 1 { _ = store.deleteDrawer(id: group.id) }
                }
                store.switchDrawer(to: originalCurrent)
            }

            let groupA = originalCurrent
            guard let groupB = store.createDrawer(named: "读取-\(UUID().uuidString.prefix(6))") else {
                return XCTFail("应能新建分组")
            }
            store.items = []
            for idx in 0..<3 {
                let url = dir.appendingPathComponent("甲\(idx).txt")
                try Data("x".utf8).write(to: url)
                store.items.append(ShelfItem(url: url, drawerID: groupA))
            }
            let ghost = ShelfItem(url: dir.appendingPathComponent("幽灵.txt"), drawerID: groupA)
            store.items.append(ghost)
            store.switchDrawer(to: groupA)

            XCTAssertEqual(DrawerCommands.list().count, 3, "当前分组 3 个存在文件，幽灵条目被剔除")
            XCTAssertEqual(DrawerCommands.list(group: store.drawers.first { $0.id == groupB }?.name).count, 0, "指定空分组")

            store.switchDrawer(to: groupB)
            let bFile = dir.appendingPathComponent("乙.txt")
            try Data("b".utf8).write(to: bFile)
            store.items.append(ShelfItem(url: bFile, drawerID: groupB))
            XCTAssertEqual(DrawerCommands.list(limit: 10).map(\.lastPathComponent), ["乙.txt"], "跨组读取不串组")

            store.switchDrawer(to: groupA)
            XCTAssertEqual(DrawerCommands.list(limit: 2).count, 2, "limit 生效（倒序取最新）")
        }
    }

    /// ensureDrawer：存在即切换、不存在即创建、非法名保持当前
    func testEnsureDrawerSemantics() {
        MainActor.assumeIsolated {
            let store = ShelfStore.shared
            let originalDrawers = store.drawers
            let originalCurrent = store.currentDrawerID
            defer {
                for group in store.drawers where !originalDrawers.contains(where: { $0.id == group.id }) {
                    if store.drawers.count > 1 { _ = store.deleteDrawer(id: group.id) }
                }
                store.switchDrawer(to: originalCurrent)
            }

            let name = "确保-\(UUID().uuidString.prefix(6))"
            let created = store.ensureDrawer(named: name)
            XCTAssertEqual(store.currentDrawerID, created)
            XCTAssertEqual(store.drawers.first { $0.id == created }?.name, name)

            // 再 ensure 同名 → 切换到既有分组，不新建
            let count = store.drawers.count
            let again = store.ensureDrawer(named: name)
            XCTAssertEqual(again, created)
            XCTAssertEqual(store.drawers.count, count)

            // 空白名 → 保持当前分组
            let before = store.currentDrawerID
            store.ensureDrawer(named: "   ")
            XCTAssertEqual(store.currentDrawerID, before)
        }
    }
}
