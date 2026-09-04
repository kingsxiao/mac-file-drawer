import XCTest
import AppKit
@testable import FileDrawer

/// 拖出即移走：处置决策（纯函数）+ 抽屉侧移除 + 废纸篓
@MainActor
final class DragOutMoveTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("DragOutMoveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    private func makeFile(_ name: String = "样本-\(UUID().uuidString).txt") throws -> URL {
        let url = workspace.appendingPathComponent(name)
        try "内容".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 处置决策（纯函数）

    func testDispositionCopyKeepsByDefault() {
        XCTAssertEqual(
            DragOutSupport.disposition(for: .copy, landedOnRow: false, removeOnCopy: false),
            .keep
        )
    }

    func testDispositionCopyRemovesUndoableWhenSettingOn() {
        XCTAssertEqual(
            DragOutSupport.disposition(for: .copy, landedOnRow: false, removeOnCopy: true),
            .removeUndoable
        )
    }

    func testDispositionMoveRemovesSilently() {
        XCTAssertEqual(
            DragOutSupport.disposition(for: .move, landedOnRow: false, removeOnCopy: false),
            .removeSilently(trashed: false)
        )
    }

    func testDispositionDeleteRemovesSilentlyAsTrashed() {
        XCTAssertEqual(
            DragOutSupport.disposition(for: .delete, landedOnRow: false, removeOnCopy: false),
            .removeSilently(trashed: true)
        )
    }

    func testDispositionCancelledKeeps() {
        XCTAssertEqual(
            DragOutSupport.disposition(for: [], landedOnRow: false, removeOnCopy: true),
            .keep
        )
        // 目标端拒绝 / 非拷贝移动类操作（generic）同样保留
        XCTAssertEqual(
            DragOutSupport.disposition(for: .generic, landedOnRow: false, removeOnCopy: true),
            .keep
        )
    }

    func testDispositionLandedOnRowAlwaysKeeps() {
        // 落在行内 = 排序（即使目标端报了 .move，也不是拖出）
        XCTAssertEqual(
            DragOutSupport.disposition(for: .move, landedOnRow: true, removeOnCopy: true),
            .keep
        )
    }

    // MARK: - 抽屉侧移除语义

    func testRemoveDraggedOutDropsUndoSnapshotAndNotices() throws {
        let store = ShelfStore.shared
        let original = store.items
        defer { store.items = original }

        let url = try makeFile()
        store.add(urls: [url])
        let item = try XCTUnwrap(store.items.first { $0.path == url.standardizedFileURL.path })

        store.removeDraggedOut([item], trashed: false)
        XCTAssertFalse(store.items.contains { $0.id == item.id }, "条目应随源文件移走")
        XCTAssertNil(store.undoSnapshot, "源文件已被目标端移走，还原快照没有意义")
        XCTAssertNotNil(store.notice, "应给出移走去向的轻提示")

        // 移走不该删除还在磁盘上的文件（移动由目标端完成，这里只清条目）
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCopyPlusRemoveOnDragOutRemainsUndoable() throws {
        let store = ShelfStore.shared
        let original = store.items
        defer { store.items = original }

        let url = try makeFile()
        store.add(urls: [url])
        let item = try XCTUnwrap(store.items.first { $0.path == url.standardizedFileURL.path })

        // 处置链路：copy + removeOnCopy=true → 可还原移除
        let disposition = DragOutSupport.disposition(for: .copy, landedOnRow: false, removeOnCopy: true)
        XCTAssertEqual(disposition, .removeUndoable)
        store.remove([item])
        XCTAssertNotNil(store.undoSnapshot, "源文件仍在原位，应可还原")
        XCTAssertEqual(store.undoLastRemoval(), 1)
        XCTAssertTrue(store.items.contains { $0.path == url.standardizedFileURL.path })
    }

    func testTrashOriginalsTrashesFileAndRemovesEntry() throws {
        let store = ShelfStore.shared
        let original = store.items
        defer { store.items = original }

        let existing = try makeFile()
        let missingURL = workspace.appendingPathComponent("已不存在-\(UUID().uuidString).txt")
        store.add(urls: [existing, missingURL])
        let existingItem = try XCTUnwrap(store.items.first { $0.path == existing.standardizedFileURL.path })
        let missingItem = try XCTUnwrap(store.items.first { $0.path == missingURL.standardizedFileURL.path })

        let trashed = store.trashOriginals([existingItem, missingItem])
        XCTAssertEqual(trashed, 1, "只有磁盘上仍存在的文件能进废纸篓")
        XCTAssertFalse(store.items.contains { $0.id == existingItem.id })
        XCTAssertTrue(store.items.contains { $0.id == missingItem.id }, "失效条目不动")
        XCTAssertFalse(FileManager.default.fileExists(atPath: existing.path), "源文件应已离开原位（进废纸篓）")
    }

    // MARK: - 拖拽粘贴板条目（真实文件才可拖出）

    func testPasteboardItemsSkipMissingFiles() throws {
        let existing = try makeFile()
        let present = ShelfItem(url: existing)
        let missing = ShelfItem(url: workspace.appendingPathComponent("没了-\(UUID().uuidString).txt"))
        let items = DragOutSupport.pasteboardItems(for: [present, missing])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].string(forType: .string), present.name)
    }
}
