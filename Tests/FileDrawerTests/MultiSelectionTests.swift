import XCTest
@testable import FileDrawer

/// 多选（⌘/⇧ 点击、⌘A）与批量操作目标的选择语义
final class MultiSelectionTests: XCTestCase {

    private func makeItems() -> [ShelfItem] {
        [
            ShelfItem(url: URL(fileURLWithPath: "/tmp/甲.txt"), addedAt: Date(timeIntervalSince1970: 1000)),
            ShelfItem(url: URL(fileURLWithPath: "/tmp/乙.txt"), addedAt: Date(timeIntervalSince1970: 2000)),
            ShelfItem(url: URL(fileURLWithPath: "/tmp/丙.txt"), addedAt: Date(timeIntervalSince1970: 3000)),
        ]
    }

    /// ⌘点击累积选中；再点已选条目则取消，锚点回退到集合内剩余条目
    func testToggleSelectAccumulatesAndRemoves() {
        MainActor.assumeIsolated {
            let model = InteractionModel()
            let items = makeItems()

            model.select(items[0])
            model.toggleSelect(items[1])
            XCTAssertEqual(model.selectedIDs, Set([items[0].id, items[1].id]))
            XCTAssertEqual(model.selectedID, items[1].id, "锚点跟随最后操作的条目")

            model.toggleSelect(items[1])
            XCTAssertEqual(model.selectedIDs, [items[0].id])
            XCTAssertEqual(model.selectedID, items[0].id, "取消的是锚点时回退到集合内第一条")
        }
    }

    /// ⇧点击选中锚点到目标之间的连续区间，锚点不动
    func testExtendSelectionSelectsRange() {
        MainActor.assumeIsolated {
            let model = InteractionModel()
            let items = makeItems()

            model.select(items[0])
            model.extendSelection(to: items[2], within: items)
            XCTAssertEqual(model.selectedIDs, Set(items.map(\.id)))
            XCTAssertEqual(model.selectedID, items[0].id, "区间选择不移动锚点")

            // 反向区间同样成立
            model.select(items[2])
            model.extendSelection(to: items[0], within: items)
            XCTAssertEqual(model.selectedIDs, Set(items.map(\.id)))
        }
    }

    /// ⇧点击时若没有锚点（首次点击），退化为普通单选
    func testExtendSelectionWithoutAnchorFallsBackToSingleSelect() {
        MainActor.assumeIsolated {
            let model = InteractionModel()
            let items = makeItems()

            model.extendSelection(to: items[1], within: items)
            XCTAssertEqual(model.selectedIDs, [items[1].id])
        }
    }

    /// ⌘A 全选；已有锚点在集合内时保持锚点
    func testSelectAll() {
        MainActor.assumeIsolated {
            let model = InteractionModel()
            let items = makeItems()

            model.select(items[1])
            model.selectAll(in: items)
            XCTAssertEqual(model.selectedIDs, Set(items.map(\.id)))
            XCTAssertEqual(model.selectedID, items[1].id)

            // 锚点不在展示集合（如搜索过滤后）→ 落到第一条
            model.select(items[1])
            model.selectAll(in: [items[0]])
            XCTAssertEqual(model.selectedIDs, [items[0].id])
            XCTAssertEqual(model.selectedID, items[0].id)
        }
    }

    /// 锚点赋值语义：集合外的 id 收敛为单选；集合内的 id 只移动锚点；nil 清空
    func testAssigningAnchorOutsideSelectionCollapses() {
        MainActor.assumeIsolated {
            let model = InteractionModel()
            let items = makeItems()

            model.select(items[0])
            model.toggleSelect(items[1])
            XCTAssertEqual(model.selectedIDs, Set([items[0].id, items[1].id]))

            // 赋集合外的 id：收敛为单选
            model.selectedID = items[2].id
            XCTAssertEqual(model.selectedIDs, [items[2].id])

            // 赋集合内的 id：只移动锚点，集合保持
            model.select(items[0])
            model.toggleSelect(items[1])
            model.selectedID = items[0].id
            XCTAssertEqual(model.selectedIDs, Set([items[0].id, items[1].id]))
            XCTAssertEqual(model.selectedID, items[0].id)

            // nil：清空
            model.selectedID = nil
            XCTAssertTrue(model.selectedIDs.isEmpty)
        }
    }

    /// 方向键移动后收敛为单选（多选不被键盘导航意外保留）
    func testMoveSelectionCollapsesMultiSelection() {
        MainActor.assumeIsolated {
            let model = InteractionModel()
            let items = makeItems()

            model.select(items[1])
            model.selectAll(in: items)
            model.moveSelection(by: -1, within: items)
            XCTAssertEqual(model.selectedIDs, [items[0].id])
            XCTAssertEqual(model.selectedID, items[0].id)
        }
    }

    /// 行内操作目标：行在多选集合里 → 整个集合；否则只有该行
    func testSelectionTargetsFollowsFinderSemantics() {
        MainActor.assumeIsolated {
            let model = InteractionModel()
            let items = makeItems()

            // 无多选：目标只有点击行
            XCTAssertEqual(model.selectionTargets(containing: items[0], in: items).map(\.id), [items[0].id])

            // 多选且行在集合内：整批
            model.select(items[0])
            model.toggleSelect(items[2])
            XCTAssertEqual(
                model.selectionTargets(containing: items[2], in: items).map(\.id),
                [items[0].id, items[2].id]
            )

            // 多选但行不在集合内：右键点到的行是新对象
            XCTAssertEqual(model.selectionTargets(containing: items[1], in: items).map(\.id), [items[1].id])
        }
    }

    /// 条目移除后：集合按可见性裁剪；锚点失效时优先落到集合内剩余条目
    func testReconcileTrimsSelectionAndRepairsAnchor() {
        MainActor.assumeIsolated {
            let model = InteractionModel()
            let items = makeItems()

            model.select(items[0])
            model.toggleSelect(items[1])
            model.toggleSelect(items[2])
            // 模拟移除锚点 items[0] 后的展示列表
            let remaining = Array(items.dropFirst())
            model.reconcileAfterListChange(with: remaining)
            XCTAssertEqual(model.selectedIDs, Set(remaining.map(\.id)))
            XCTAssertNotNil(model.selectedID)
            XCTAssertTrue(model.selectedIDs.contains(model.selectedID!), "锚点应回退到剩余集合内")

            // 全部移除：清空选中
            model.reconcileAfterListChange(with: [])
            XCTAssertTrue(model.selectedIDs.isEmpty)
            XCTAssertNil(model.selectedID)
        }
    }

    /// 批量移除进同一条撤销快照，可整批还原
    func testBatchRemoveProducesSingleUndoSnapshot() throws {
        try MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let store = ShelfStore.shared
            let original = store.items
            store.items = [
                ShelfItem(url: dir.appendingPathComponent("甲.txt")),
                ShelfItem(url: dir.appendingPathComponent("乙.txt")),
                ShelfItem(url: dir.appendingPathComponent("丙.txt")),
            ]
            defer {
                store.discardUndo()
                store.items = original
            }

            store.remove([store.items[0], store.items[2]])
            XCTAssertEqual(store.items.map(\.name), ["乙.txt"])
            XCTAssertEqual(store.undoSnapshot?.entries.count, 2, "一次批量移除 = 一条快照")

            let restored = store.undoLastRemoval()
            XCTAssertEqual(restored, 2)
            XCTAssertEqual(Set(store.items.map(\.name)), Set(["甲.txt", "乙.txt", "丙.txt"]))
        }
    }
}
