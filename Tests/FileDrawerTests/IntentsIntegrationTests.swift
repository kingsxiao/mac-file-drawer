import XCTest
import AppIntents
@testable import FileDrawer

/// App Intents 拼装层集成测试：与 URL 冒烟对等，覆盖 9 个意图的参数拼装与往返语义。
/// （@Parameter 的 wrapped 注入在裸 xctest 进程不可靠——经独立 runloop 探针确认；
///   故直呼各意图的显式参数 run 层，perform 仅委托 run，行为一致。）
final class IntentsIntegrationTests: XCTestCase {

    private var dir: URL!
    private var store: ShelfStore!
    private var originalItems: [ShelfItem]!
    private var originalDrawers: [DrawerGroup]!
    private var originalCurrent: UUID!
    private var groupName: String!

    override func setUpWithError() throws {
        try MainActor.assumeIsolated {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            store = ShelfStore.shared
            originalItems = store.items
            originalDrawers = store.drawers
            originalCurrent = store.currentDrawerID
            groupName = "意图\(UUID().uuidString.prefix(6))"
            store.items = []
            _ = store.createDrawer(named: groupName)
            for name in ["甲.txt", "乙.txt"] {
                let url = dir.appendingPathComponent(name)
                try Data(name.utf8).write(to: url)
                store.items.append(ShelfItem(url: url, drawerID: store.currentDrawerID))
            }
        }
    }

    override func tearDownWithError() throws {
        MainActor.assumeIsolated {
            store.discardUndo()
            store.items = originalItems
            for group in store.drawers where !originalDrawers.contains(where: { $0.id == group.id }) {
                if store.drawers.count > 1 { _ = store.deleteDrawer(id: group.id) }
            }
            store.switchDrawer(to: originalCurrent)
        }
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String) -> URL { dir.appendingPathComponent(name) }

    private var groupItemCount: Int {
        MainActor.assumeIsolated {
            store.items.filter { $0.drawerID == store.currentDrawerID }.count
        }
    }

    @MainActor
    func testAddAndListIntents() throws {
        // 放入：路径 → 分组，返回新增数
        // 新文件（甲/乙已在抽屉里，重加会被去重跳过）
        let 丙 = file("丙.txt")
        try Data("丙".utf8).write(to: 丙)
        XCTAssertEqual(AddFilesToDrawerIntent.run(paths: [丙.path], group: groupName), 1)
        XCTAssertEqual(groupItemCount, 3, "2 原有 + 1 新增")

        // 重复放入：返回 0（去重）
        XCTAssertEqual(AddFilesToDrawerIntent.run(paths: [丙.path], group: groupName), 0)

        // 读取：最新在前 + limit（丙刚加入，最新）
        let urls = ListDrawerItemsIntent.run(group: groupName, limit: 1)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["丙.txt"])
    }

    @MainActor
    func testRemoveAndClearIntentsUndoable() {
        XCTAssertEqual(RemoveDrawerItemsIntent.run(group: groupName, limit: 1), 1)
        XCTAssertEqual(groupItemCount, 1)
        XCTAssertEqual(store.undoLastRemoval(), 1, "意图移除同样可还原")

        XCTAssertEqual(ClearDrawerGroupIntent.run(group: groupName), 2, "还原后的 2 条被清空")
        XCTAssertNotNil(store.undoSnapshot, "清空走可还原路径")
    }

    @MainActor
    func testPinSendToFrontAndMoveIntents() {
        XCTAssertEqual(PinDrawerItemsIntent.run(group: groupName, limit: 1, pin: true), 1)
        XCTAssertTrue(store.items.first { $0.name == "乙.txt" }!.pinned, "最新一条被置顶")

        XCTAssertEqual(SendToFrontIntent.run(group: groupName, limit: 1), 1)
        XCTAssertEqual(store.items.first?.name, "乙.txt", "最新一条置前")

        let target = "归档\(UUID().uuidString.prefix(4))"
        XCTAssertEqual(MoveItemsToGroupIntent.run(group: groupName, target: target, limit: 1), 1)
        XCTAssertEqual(store.drawers.filter { $0.name == target }.count, 1, "目标分组已创建")
    }

    @MainActor
    func testRenameAndExpansionIntents() throws {
        let renamed = RenameItemIntent.run(path: file("甲.txt").path, newName: "甲改.txt")
        XCTAssertTrue(renamed)
        XCTAssertTrue(store.items.contains { $0.name == "甲改.txt" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: file("甲改.txt").path))

        // 展开意图：测试进程无 AppDelegate/NSApp 时安全 no-op（不抛错即过）
        SetDrawerExpansionIntent.run(command: .toggle)
        SetDrawerExpansionIntent.run(command: .expand)
        SetDrawerExpansionIntent.run(command: .collapse)
    }
}
