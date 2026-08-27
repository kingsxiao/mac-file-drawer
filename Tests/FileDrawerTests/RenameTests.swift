import XCTest
@testable import FileDrawer

/// 条目重命名：同目录改名、同名去重、失效与非法输入守卫
final class RenameTests: XCTestCase {

    /// 改名成功：磁盘文件移动、条目路径与类型同步更新
    func testRenameMovesFileAndUpdatesItem() throws {
        try MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let store = ShelfStore.shared
            let original = store.items
            let url = dir.appendingPathComponent("旧名字.txt")
            try Data("内容".utf8).write(to: url)
            store.items = [ShelfItem(url: url)]
            defer { store.items = original }

            XCTAssertTrue(store.rename(id: store.items[0].id, to: "新名字.txt"))
            XCTAssertEqual(store.items[0].name, "新名字.txt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("新名字.txt").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "旧文件应已被改名移走")
        }
    }

    /// 目标名冲突：自动追加 " 2" 序号
    func testRenameCollisionAppendsSuffix() throws {
        try MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let store = ShelfStore.shared
            let original = store.items
            try Data("a".utf8).write(to: dir.appendingPathComponent("甲.txt"))
            try Data("b".utf8).write(to: dir.appendingPathComponent("乙.txt"))
            store.items = [
                ShelfItem(url: dir.appendingPathComponent("甲.txt")),
                ShelfItem(url: dir.appendingPathComponent("乙.txt")),
            ]
            defer { store.items = original }

            // 把乙改名为甲：冲突 → 落成 "甲 2.txt"
            XCTAssertTrue(store.rename(id: store.items[1].id, to: "甲.txt"))
            XCTAssertEqual(store.items[1].name, "甲 2.txt")
            XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("甲 2.txt"), encoding: .utf8), "b")
        }
    }

    /// 名称未变化 / 非法输入 / 文件不存在
    func testRenameGuards() throws {
        try MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let store = ShelfStore.shared
            let original = store.items
            try Data("a".utf8).write(to: dir.appendingPathComponent("甲.txt"))
            store.items = [ShelfItem(url: dir.appendingPathComponent("甲.txt"))]
            defer { store.items = original }

            // 同名：视为成功且不产生任何变化
            XCTAssertTrue(store.rename(id: store.items[0].id, to: "甲.txt"))
            XCTAssertEqual(store.items[0].name, "甲.txt")

            // 全空白：拒绝
            XCTAssertFalse(store.rename(id: store.items[0].id, to: "   "))

            // 文件不存在：拒绝
            try FileManager.default.removeItem(at: dir.appendingPathComponent("甲.txt"))
            XCTAssertFalse(store.rename(id: store.items[0].id, to: "乙.txt"))
        }
    }

    /// 改名后类型随新扩展名重新识别
    func testRenameRecomputesKind() throws {
        try MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let store = ShelfStore.shared
            let original = store.items
            let url = dir.appendingPathComponent("备注.txt")
            try Data("x".utf8).write(to: url)
            store.items = [ShelfItem(url: url)]
            defer { store.items = original }

            XCTAssertEqual(store.items[0].kind.variant, .document)
            XCTAssertTrue(store.rename(id: store.items[0].id, to: "照片.jpg"))
            XCTAssertEqual(store.items[0].kind.variant, .image, "类型应随新扩展名重新识别")
        }
    }
}
