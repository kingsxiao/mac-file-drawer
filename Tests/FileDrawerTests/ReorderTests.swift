import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import FileDrawer

/// 行内拖拽排序：move 原语与排序载荷
final class ReorderTests: XCTestCase {

    private func item(_ name: String, pinned: Bool = false, drawer: UUID? = nil) -> ShelfItem {
        ShelfItem(url: URL(fileURLWithPath: "/tmp/\(name)"), pinned: pinned, drawerID: drawer)
    }

    /// 基本移动：把条目移到目标前方，其他条目顺序不变
    func testMoveBeforeTarget() {
        MainActor.assumeIsolated {
            let store = ShelfStore.shared
            let original = store.items
            defer { store.items = original }

            store.items = [item("甲"), item("乙"), item("丙"), item("丁")]
            let ids = store.items.map(\.id)
            store.move(ids: [ids[3]], before: ids[0]) // 丁 移到 甲 前
            XCTAssertEqual(store.items.map(\.name), ["丁", "甲", "乙", "丙"])

            // 整批移动保持批内相对顺序（按列表中的相对顺序，与访达多选拖动一致）
            store.move(ids: [ids[1], ids[3]], before: ids[0])
            XCTAssertEqual(store.items.map(\.name), ["丁", "乙", "甲", "丙"], "批内保持列表相对顺序（丁在乙前）")
        }
    }

    /// 拖到自己 / 目标在移动块里：无操作
    func testMoveOntoItselfIsNoOp() {
        MainActor.assumeIsolated {
            let store = ShelfStore.shared
            let original = store.items
            defer { store.items = original }

            store.items = [item("甲"), item("乙")]
            let ids = store.items.map(\.id)
            store.move(ids: [ids[0]], before: ids[0])
            XCTAssertEqual(store.items.map(\.name), ["甲", "乙"])
            store.move(ids: [ids[0], ids[1]], before: ids[1])
            XCTAssertEqual(store.items.map(\.name), ["甲", "乙"])
        }
    }

    /// 跨置顶分区：拖进置顶区 = 置顶；拖出 = 取消置顶
    func testMoveAcrossPinnedPartitionTogglesPin() {
        MainActor.assumeIsolated {
            let store = ShelfStore.shared
            let original = store.items
            defer { store.items = original }

            store.items = [
                item("置顶甲", pinned: true),
                item("普通甲"),
                item("普通乙"),
            ]
            let ids = store.items.map(\.id)

            // 普通乙 拖到 置顶甲 前 → 变置顶
            store.move(ids: [ids[2]], before: ids[0])
            XCTAssertEqual(store.items[0].name, "普通乙")
            XCTAssertTrue(store.items[0].pinned, "拖进置顶区应置顶")

            // 置顶甲（现在 index 1）拖到普通乙（已置顶）…改用：取消场景
            store.items = [
                item("置顶甲", pinned: true),
                item("普通甲"),
                item("普通乙"),
            ]
            let ids2 = store.items.map(\.id)
            store.move(ids: [ids2[0]], before: ids2[1]) // 置顶甲 拖到 普通甲 前 → 取消置顶
            XCTAssertFalse(store.items.first { $0.name == "置顶甲" }!.pinned, "拖出置顶区应取消置顶")
        }
    }

    /// 排序载荷注册 / 读取往返（同进程自定义类型）
    func testReorderPayloadRoundTrip() {
        let id = UUID()
        let provider = NSItemProvider()
        ReorderDrag.register(provider, id: id)

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(ReorderDrag.typeIdentifier))
        XCTAssertEqual(ReorderDrag.itemID(from: provider), id)

        // 未注册的 provider 读不到 id
        let plain = NSItemProvider()
        XCTAssertNil(ReorderDrag.itemID(from: plain))
    }
}
