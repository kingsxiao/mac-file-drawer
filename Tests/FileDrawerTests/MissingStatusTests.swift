import XCTest
@testable import FileDrawer

/// 失效条目实时检测：后台扫描 → missingIDs → 展示层降透明
final class MissingStatusTests: XCTestCase {

    /// 主线程自旋等待（存在性扫描在 utility 队列异步完成）
    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// 纯函数扫描：磁盘上不存在的条目被标出
    func testScanMissingMarksOnlyAbsentFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let present = ShelfItem(url: dir.appendingPathComponent("在的.txt"))
        try Data("x".utf8).write(to: present.url)
        let absent = ShelfItem(url: dir.appendingPathComponent("不在.txt"))

        let missing = ShelfStore.scanMissing([present, absent])
        XCTAssertEqual(missing, [absent.id])
    }

    /// 端到端：文件被外部删除后刷新扫描，missingIDs 更新；移除条目后集合回收
    func testRefreshMissingStatusUpdatesLive() throws {
        try MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let a = ShelfItem(url: dir.appendingPathComponent("甲.txt"))
            let b = ShelfItem(url: dir.appendingPathComponent("乙.txt"))
            try Data("a".utf8).write(to: a.url)
            try Data("b".utf8).write(to: b.url)

            let store = ShelfStore.shared
            let original = store.items
            store.items = [a, b]
            defer { store.items = original }

            // 初始都在
            store.refreshMissingStatus()
            waitUntil { store.missingIDs.isEmpty }
            XCTAssertTrue(store.missingIDs.isEmpty)

            // 外部删除乙 → 刷新后标记
            try FileManager.default.removeItem(at: b.url)
            store.refreshMissingStatus()
            waitUntil { store.missingIDs == [b.id] }
            XCTAssertEqual(store.missingIDs, [b.id])

            // 移除失效条目 → 集合回收
            store.remove([b])
            XCTAssertTrue(store.missingIDs.isEmpty, "条目移除时失效标记一并回收")
        }
    }

    /// 清空抽屉后失效集合归零
    func testClearResetsMissingIDs() throws {
        try MainActor.assumeIsolated {
            let store = ShelfStore.shared
            let original = store.items
            let ghost = ShelfItem(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("幽灵-\(UUID().uuidString).txt"))
            store.items = [ghost]
            defer { store.items = original }

            store.refreshMissingStatus()
            waitUntil { store.missingIDs == [ghost.id] }

            store.clear()
            waitUntil { store.missingIDs.isEmpty }
            XCTAssertTrue(store.missingIDs.isEmpty)
        }
    }
}
