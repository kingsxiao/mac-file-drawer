import XCTest
import AppKit
@testable import FileDrawer

/// 多选拖出：粘贴板条目构造与拖拽预览图
final class DragOutMultiTests: XCTestCase {

    /// 存在的文件各生成一条 fileURL 粘贴板条目；失效条目被剔除
    func testPasteboardItemsPerExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appendingPathComponent("甲.txt")
        let b = dir.appendingPathComponent("乙.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        let ghost = ShelfItem(url: dir.appendingPathComponent("幽灵.txt"))

        let items = [ShelfItem(url: a), ShelfItem(url: b), ghost]
        let pbItems = DragOutSupport.pasteboardItems(for: items)
        XCTAssertEqual(pbItems.count, 2, "失效条目不参与拖出")

        let urls = pbItems.compactMap { URL(string: $0.string(forType: .fileURL) ?? "") }
        XCTAssertEqual(Set(urls), Set([a, b]))
        XCTAssertEqual(pbItems.map { $0.string(forType: .string) }, ["甲.txt", "乙.txt"], "名称作为字符串表示便于目标端展示")
    }

    /// 拖拽预览图：非空、单批无角标也不崩溃
    func testDragImageRenders() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("图标样本.txt")
        try Data("x".utf8).write(to: file)
        let item = ShelfItem(url: file)

        let single = DragOutSupport.dragImage(for: [item])
        XCTAssertEqual(single.size.width, 56, accuracy: 1)
        XCTAssertEqual(single.size.height, 56, accuracy: 1)

        let batch = DragOutSupport.dragImage(for: [item, item, item])
        XCTAssertEqual(batch.size.width, 56, accuracy: 1)

        // 空集合也不崩溃（返回占位尺寸）
        XCTAssertEqual(DragOutSupport.dragImage(for: []).size.width, 56, accuracy: 1)
    }
}
