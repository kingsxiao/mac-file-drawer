import XCTest
@testable import FileDrawer

/// 撤销体系：移除 / 清空 / 清理失效条目后可还原，策略清理不可还原
final class RemovalUndoTests: XCTestCase {
    private var inbox: URL!

    override func setUpWithError() throws {
        inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDrawerUndoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        // 清扫指向临时目录，避免动到真实收件箱
        MainActor.assumeIsolated {
            ShelfStore.shared.inboxDirectoryOverride = inbox
        }
    }

    override func tearDownWithError() throws {
        MainActor.assumeIsolated {
            ShelfStore.shared.discardUndo()
            ShelfStore.shared.inboxDirectoryOverride = nil
        }
        try? FileManager.default.removeItem(at: inbox)
    }

    @MainActor
    private func stage(_ items: [ShelfItem]) -> [ShelfItem] {
        let store = ShelfStore.shared
        let original = store.items
        store.items = items
        return original
    }

    @MainActor
    private func fileItem(_ name: String, ageMinutes: Double = 0) -> ShelfItem {
        ShelfItem(
            url: URL(fileURLWithPath: "/tmp/undo-\(UUID().uuidString)-\(name)"),
            addedAt: Date(timeIntervalSinceNow: -ageMinutes * 60)
        )
    }

    // MARK: - 单条移除与还原

    @MainActor
    func testRemoveRecordsSnapshotAndUndoRestoresPosition() {
        let store = ShelfStore.shared
        let original = stage([fileItem("a"), fileItem("b", ageMinutes: 1), fileItem("c", ageMinutes: 2)])
        defer { store.items = original }

        guard let b = store.items.first(where: { $0.name.contains("b") }) else {
            return XCTFail("缺少条目 b")
        }
        store.remove(b)
        XCTAssertEqual(store.items.map(\.name).count, 2)
        XCTAssertEqual(store.undoSnapshot?.summary, "已移除「\(b.name)」")

        let restored = store.undoLastRemoval()
        XCTAssertEqual(restored, 1)
        XCTAssertNil(store.undoSnapshot)
        XCTAssertEqual(store.items.count, 3)
        // 还原到原位置：b 仍排在第二
        XCTAssertTrue(store.items[1].name.contains("b"))
    }

    @MainActor
    func testSecondRemovalReplacesSnapshot() {
        let store = ShelfStore.shared
        let original = stage([fileItem("a"), fileItem("b", ageMinutes: 1), fileItem("c", ageMinutes: 2)])
        defer { store.items = original }

        let a = store.items[0]
        let b = store.items[1]
        store.remove(a)
        store.remove(b)

        // 只保留最近一次移除的快照
        XCTAssertEqual(store.undoSnapshot?.entries.count, 1)
        XCTAssertEqual(store.undoSnapshot?.summary, "已移除「\(b.name)」")

        store.undoLastRemoval()
        // a 已不可还原
        XCTAssertEqual(store.items.count, 2)
        XCTAssertFalse(store.items.contains(where: { $0.id == a.id }))
        XCTAssertTrue(store.items.contains(where: { $0.id == b.id }))
    }

    // MARK: - 清空与还原

    @MainActor
    func testClearRecordsAllAndUndoRestoresOrder() {
        let store = ShelfStore.shared
        let a = fileItem("a")
        let b = fileItem("b", ageMinutes: 1)
        let original = stage([a, b])
        defer { store.items = original }

        store.clear()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.undoSnapshot?.entries.count, 2)
        XCTAssertTrue(store.undoSnapshot?.summary.contains("已清空抽屉（2 个条目）") ?? false)

        // 空抽屉再次清空：不产生新快照
        store.clear()
        XCTAssertEqual(store.undoSnapshot?.entries.count, 2)

        let restored = store.undoLastRemoval()
        XCTAssertEqual(restored, 2)
        XCTAssertEqual(store.items.map(\.id), [a.id, b.id], "还原应保持原始顺序")
    }

    // MARK: - 放弃还原

    @MainActor
    func testDiscardUndoDropsSnapshot() {
        let store = ShelfStore.shared
        let original = stage([fileItem("a")])
        defer { store.items = original }

        store.remove(store.items[0])
        XCTAssertNotNil(store.undoSnapshot)
        store.discardUndo()
        XCTAssertNil(store.undoSnapshot)
        XCTAssertEqual(store.undoLastRemoval(), 0, "放弃后还原无效")
    }

    // MARK: - 策略清理不产生快照（静默维护 ≠ 用户操作）

    @MainActor
    func testPolicyTrimDoesNotRecordSnapshot() {
        let store = ShelfStore.shared
        let original = stage((0..<21).map { fileItem("f\($0)", ageMinutes: Double(21 - $0)) })
        defer { store.items = original }

        let settings = AppSettings.shared
        let originalMax = settings.maxItems
        defer { settings.maxItems = originalMax }

        store.discardUndo()
        settings.maxItems = .m20

        let deadline = Date().addingTimeInterval(3)
        while store.items.count != 20, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(store.items.count, 20)
        XCTAssertNil(store.undoSnapshot, "容量淘汰不应出现还原提示")
    }

    // MARK: - 收件箱物化文件的生命周期

    @MainActor
    func testManagedSnippetSurvivesUntilUndoWindowCloses() throws {
        let store = ShelfStore.shared
        let original = stage([])
        defer { store.items = original }

        let url = try XCTUnwrap(InboxStore.materialize(text: "会被还原的便签", directory: inbox))
        store.add(urls: [url])
        guard let item = store.items.first else { return XCTFail("物化条目未入列") }

        store.remove(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "撤销窗口内文件必须保留")

        store.undoLastRemoval()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "还原后文件仍在")

        store.remove(store.items[0])
        store.discardUndo()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "撤销窗口关闭后回收物化文件")
    }

    @MainActor
    func testSweepKeepsExternallyMovedManagedFile() throws {
        // 用户把物化文件「移动到文件夹」后路径已改指外部：即使移除条目也不应误删外部文件
        let store = ShelfStore.shared
        let original = stage([])
        defer { store.items = original }

        let url = try XCTUnwrap(InboxStore.materialize(text: "已移动的便签", directory: inbox))
        store.add(urls: [url])
        guard let item = store.items.first else { return XCTFail("条目未入列") }

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("UndoTests-外移-\(UUID().uuidString).txt")
        try FileManager.default.moveItem(at: url, to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        store.updatePath(id: item.id, to: outside)

        store.remove(store.items[0])
        store.discardUndo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "外部文件不归收件箱管")
    }
}
