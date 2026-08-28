import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import FileDrawer

/// 行内拖拽排序：move 原语与排序载荷
final class ReorderTests: XCTestCase {

    private func item(_ name: String, pinned: Bool = false, drawer: UUID? = nil, age: TimeInterval = 0) -> ShelfItem {
        ShelfItem(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            addedAt: Date(timeIntervalSinceNow: -age),
            pinned: pinned,
            drawerID: drawer
        )
    }

    /// 冻结顺序原语：把该分组条目在 items 中的相对顺序改写为展示顺序，
    /// 其他分组条目原地不动、条目不增不减
    func testAdoptDisplayOrderRewritesGroupOrderOnly() {
        MainActor.assumeIsolated {
            let store = ShelfStore.shared
            let original = store.items
            defer { store.items = original }

            // resolvedDrawerID 只认 drawers 里真实存在的分组，先注册两个临时分组
            guard let drawerA = store.createDrawer(named: "冻结顺序A-\(UUID().uuidString.prefix(6))", switchTo: false),
                  let drawerB = store.createDrawer(named: "冻结顺序B-\(UUID().uuidString.prefix(6))", switchTo: false) else {
                return XCTFail("临时分组创建失败")
            }
            defer { _ = store.deleteDrawer(id: drawerA); _ = store.deleteDrawer(id: drawerB) }

            // 存储顺序（添加顺序）：A丙、X、A乙、Y、A甲 —— A 组与 B 组条目穿插
            store.items = [
                item("A丙", drawer: drawerA, age: 300),
                item("X", drawer: drawerB, age: 250),
                item("A乙", drawer: drawerA, age: 200),
                item("Y", drawer: drawerB, age: 100),
                item("A甲", drawer: drawerA, age: 10),
            ]

            let model = InteractionModel()
            let displayed = model.displayItems(from: store.items(in: drawerA), sort: .timeNewestFirst)
            XCTAssertEqual(displayed.map(\.name), ["A甲", "A乙", "A丙"], "最新在前")

            store.adoptDisplayOrder(displayed, for: drawerA)
            XCTAssertEqual(store.items.count, 5)
            XCTAssertEqual(
                store.items.filter { $0.drawerID == drawerA }.map(\.name),
                ["A甲", "A乙", "A丙"],
                "A 组条目的相对顺序 = 展示顺序"
            )
            XCTAssertEqual(
                store.items.filter { $0.drawerID == drawerB }.map(\.name),
                ["X", "Y"],
                "其他分组条目相对顺序不受影响"
            )
        }
    }

    /// 回归：非 manual 排序下拖拽排序。展示顺序（最新在前）与存储顺序整表倒置，
    /// 不冻结直接切 manual + move 会以存储顺序为基准——整表跳序、落点与屏幕所见
    /// 对不上（拖了等于乱拖）。冻结后落点即所见位置，其他条目保持屏幕顺序。
    func testDropUnderSortedModeLandsWhereUserSeesIt() {
        MainActor.assumeIsolated {
            let store = ShelfStore.shared
            let original = store.items
            defer { store.items = original }

            // 存储顺序 = 添加顺序；屏幕「最新在前」显示 [甲, 乙, 丙]
            store.items = [item("丙", age: 300), item("乙", age: 200), item("甲", age: 10)]
            let model = InteractionModel()

            // 用户把屏幕第 1 行「甲」拖到第 3 行「丙」上松手（向下拖 = 插到丙后
            // → 修复后预期屏幕 [乙, 丙, 甲]）
            let displayed = model.displayItems(from: store.items, sort: .timeNewestFirst)
            XCTAssertEqual(displayed.map(\.name), ["甲", "乙", "丙"])

            // 旧路径（不冻结直接切 manual + move）：以存储顺序为基准，甲插到存储中丙前
            let oldIDs = store.items.map(\.id) // [丙, 乙, 甲]
            store.move(ids: [oldIDs[2]], before: oldIDs[0])
            XCTAssertEqual(
                model.displayItems(from: store.items, sort: .manual).map(\.name),
                ["甲", "丙", "乙"],
                "旧路径落点错乱（回归证据）"
            )

            // 修复路径：回到同一起始布局（同对象，id 不变），先冻结屏幕所见，
            // 再按落点代理的同一数据流移动（方向感知：向下拖 = 插目标后）
            store.items = [displayed[2], displayed[1], displayed[0]] // [丙, 乙, 甲]
            store.adoptDisplayOrder(displayed, for: store.currentDrawerID)
            let insertAfter = InteractionModel.reorderInsertsAfter(
                draggedID: displayed[0].id, targetID: displayed[2].id, in: displayed
            ) ?? false
            XCTAssertTrue(insertAfter, "源在目标上方（向下拖）= 插后")
            store.move(ids: [displayed[0].id], before: displayed[2].id, after: insertAfter)
            XCTAssertEqual(
                model.displayItems(from: store.items, sort: .manual).map(\.name),
                ["乙", "丙", "甲"],
                "拖拽落点与屏幕所见一致：指示条画在丙下缘，其他条目保持屏幕顺序"
            )
        }
    }

    /// 回归：非 manual 排序下键盘 / 菜单平移（nudge）。冻结后平移沿屏幕轴：
    /// 屏幕顶部上移是无操作；中间条目下移真的在屏幕上下移。
    func testNudgeUnderSortedModeMovesOnScreenAxis() {
        MainActor.assumeIsolated {
            let store = ShelfStore.shared
            let original = store.items
            defer { store.items = original }

            let model = InteractionModel()
            let layout = [item("丙", age: 300), item("乙", age: 200), item("甲", age: 10)]

            // 屏幕顶「甲」上移：应无操作（甲已是最前）
            store.items = layout
            let ids1 = store.items.map(\.id)
            let displayed = model.displayItems(from: store.items, sort: .timeNewestFirst)
            store.adoptDisplayOrder(displayed, for: store.currentDrawerID)
            store.nudge(ids: [ids1[2]], by: -1)
            XCTAssertEqual(model.displayItems(from: store.items, sort: .manual).map(\.name), ["甲", "乙", "丙"])

            // 屏幕中间「乙」下移：屏幕上应变为 [甲, 丙, 乙]
            store.items = layout
            let ids2 = store.items.map(\.id)
            store.adoptDisplayOrder(displayed, for: store.currentDrawerID)
            store.nudge(ids: [ids2[1]], by: 1)
            XCTAssertEqual(model.displayItems(from: store.items, sort: .manual).map(\.name), ["甲", "丙", "乙"])
        }
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

    /// 方向感知落点：向下拖插目标后（after）、向上拖插目标前（before）。
    /// 固定「插目标前」时向下拖一格会插回原位 = 无操作（旧 bug）。
    func testDirectionAwareMoveAfter() {
        MainActor.assumeIsolated {
            let store = ShelfStore.shared
            let original = store.items
            defer { store.items = original }

            // 向下拖一格：甲 拖到 乙 上（源在目标上方 → after）→ 真的下移到乙后
            store.items = [item("甲"), item("乙"), item("丙")]
            var ids = store.items.map(\.id)
            store.move(ids: [ids[0]], before: ids[1], after: true)
            XCTAssertEqual(store.items.map(\.name), ["乙", "甲", "丙"], "向下拖一格必须真的移动（旧实现是无操作）")

            // 向上拖一格：丙（现在 index 2）拖到 甲 上（源在目标下方 → before）
            ids = store.items.map(\.id)
            store.move(ids: [ids[2]], before: ids[1])
            XCTAssertEqual(store.items.map(\.name), ["乙", "丙", "甲"])

            // 跳格下拖：乙 拖到 甲（末位）上 after → 移到最后
            ids = store.items.map(\.id)
            store.move(ids: [ids[0]], before: ids[2], after: true)
            XCTAssertEqual(store.items.map(\.name), ["丙", "甲", "乙"])

            // 多选整批 + after：批内保持相对顺序插到目标后
            store.items = [item("甲"), item("乙"), item("丙"), item("丁")]
            ids = store.items.map(\.id)
            store.move(ids: [ids[1], ids[3]], before: ids[0], after: true) // 乙、丁 移到 甲 后
            XCTAssertEqual(store.items.map(\.name), ["甲", "乙", "丁", "丙"])
        }
    }

    /// 方向判定原语：源在目标上方（显示顺序）= true（插后），下方 = false（插前）
    func testReorderInsertsAfterDirection() {
        let items = [
            ShelfItem(url: URL(fileURLWithPath: "/tmp/A")),
            ShelfItem(url: URL(fileURLWithPath: "/tmp/B")),
            ShelfItem(url: URL(fileURLWithPath: "/tmp/C")),
        ]
        XCTAssertNil(InteractionModel.reorderInsertsAfter(draggedID: items[0].id, targetID: items[0].id, in: items), "源 = 目标 → nil")
        XCTAssertNil(InteractionModel.reorderInsertsAfter(draggedID: UUID(), targetID: items[0].id, in: items), "源不在列表 → nil")
        XCTAssertEqual(InteractionModel.reorderInsertsAfter(draggedID: items[0].id, targetID: items[2].id, in: items), true, "源在目标上方 → 插后")
        XCTAssertEqual(InteractionModel.reorderInsertsAfter(draggedID: items[2].id, targetID: items[0].id, in: items), false, "源在目标下方 → 插前")
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

    /// 排序载荷注册：provider 携带仅本进程可见的自定义标记。标记只是落点端判别的
    /// 旁证（真实会话里 pasteboard 重建的 provider 不保证保留 .ownProcess 注册），
    /// 拖动条目 id 不从 provider 解码——见会话记录（beginReorderSession）回归
    func testReorderPayloadRegistration() {
        let provider = NSItemProvider()
        ReorderDrag.register(provider, id: UUID())

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(ReorderDrag.typeIdentifier))
        XCTAssertTrue(ReorderDrag.isReorderProvider(provider))

        // 未注册的 provider 不带标记
        XCTAssertFalse(ReorderDrag.isReorderProvider(NSItemProvider()))
    }

    /// 拖拽会话记录生命周期：开始 = 记录拖动条目 + 复位落点标记；结束（含取消）=
    /// 清记录、清残留指示条；旧会话的迟到清理（连续快速拖拽时 DragSessionObserver
    /// 轮询未跑完）不得误清新会话。
    func testReorderSessionLifecycle() {
        MainActor.assumeIsolated {
            let model = InteractionModel()

            // 新会话开始必须复位「落在行上」标记，否则排序落点会误抑制「拖出后收起」
            model.reorderLandedOnRow = true
            let oldToken = model.beginReorderSession(dragging: UUID())
            XCTAssertNotNil(model.reorderDraggedID)
            XCTAssertFalse(model.reorderLandedOnRow)

            // 接着开第二个会话（快速连续拖拽）→ 旧 token 的迟到清理不得动新会话
            let newToken = model.beginReorderSession(dragging: UUID())
            let newID = model.reorderDraggedID
            XCTAssertNotNil(newID)
            model.endReorderSession(token: oldToken)
            XCTAssertEqual(model.reorderDraggedID, newID, "旧会话的迟到清理不得清掉新会话记录")

            // 当前会话结束（落下或取消）：记录与指示条一并清掉
            model.reorderTargetID = newID
            model.reorderInsertAfter = true
            model.endReorderSession(token: newToken)
            XCTAssertNil(model.reorderDraggedID)
            XCTAssertNil(model.reorderTargetID)
            XCTAssertFalse(model.reorderInsertAfter)
            XCTAssertFalse(model.reorderLandedOnRow)
        }
    }

    /// 回归：行级落点代理的数据路径（不经 UI）。拖动条目 id 来自会话记录
    /// （不再解码 provider），松手后冻结展示顺序 + 方向感知移动，落点与屏幕所见
    /// 一致，并置「落在行上」标记抑制「拖出后自动收起」。
    func testDropFlowUsesSessionRecordAndLandsWhereSeen() {
        MainActor.assumeIsolated {
            let store = ShelfStore.shared
            let original = store.items
            defer { store.items = original }
            let model = InteractionModel()
            // 排序状态（默认模式 + 分组覆盖）持久化在 UserDefaults，跨进程/跨测试
            // 污染会让 switchToManualPreservingDisplay 误判「已是 manual」跳过冻结：
            // 本测试显式固定「最新在前」，收尾恢复原值
            let originalDefault = model.defaultSortMode
            model.defaultSortMode = .timeNewestFirst
            model.resetSortMode(for: store.currentDrawerID)
            defer {
                model.defaultSortMode = originalDefault
                model.resetSortMode(for: store.currentDrawerID)
            }

            // 屏幕按「最新在前」显示 [甲, 乙, 丙]
            store.items = [item("丙", age: 300), item("乙", age: 200), item("甲", age: 10)]
            let displayed = model.displayItems(from: store.items, sort: .timeNewestFirst)
            XCTAssertEqual(displayed.map(\.name), ["甲", "乙", "丙"])

            // onDrag 开始：会话记录屏幕第 1 行「甲」；用户向下拖到第 3 行「丙」上松手
            let token = model.beginReorderSession(dragging: displayed[0].id)
            guard let draggedID = model.reorderDraggedID else {
                return XCTFail("会话记录缺失 = 行级代理恒拒收（拖拽排序失效的旧根因）")
            }
            let insertAfter = InteractionModel.reorderInsertsAfter(
                draggedID: draggedID, targetID: displayed[2].id, in: displayed
            ) ?? false
            XCTAssertTrue(insertAfter, "向下拖 = 插目标后")
            model.reorderLandedOnRow = true

            model.switchToManualPreservingDisplay(store: store, drawerID: store.currentDrawerID)
            store.move(ids: [draggedID], before: displayed[2].id, after: insertAfter)
            XCTAssertEqual(
                model.displayItems(from: store.items, sort: .manual).map(\.name),
                ["乙", "丙", "甲"],
                "落点与屏幕所见一致：指示条画在丙下缘 → 甲落在丙后"
            )
            XCTAssertTrue(model.reorderLandedOnRow, "落在行上置位 → 抑制「拖出后自动收起」")

            // 会话收尾（DragSessionObserver 清理等价）
            model.endReorderSession(token: token)
            XCTAssertNil(model.reorderDraggedID)
            XCTAssertFalse(model.reorderLandedOnRow, "收尾复位，脏标记不得影响下一次拖拽")
        }
    }

    /// 内外拖拽判别必须用「注册类型标识包含」而不能用自定义 UTType 符合性匹配：
    /// 实测真实拖拽会话里 `itemProviders(for: [ReorderDrag.type])` 会误命中外部
    /// provider（访达拖入被当成内部排序拒收 → 拖入无任何反应的回归）。
    /// registeredTypeIdentifiers 判别对内外两个方向都是确定性的。
    func testReorderProviderDiscrimination() {
        // 内部排序拖拽：注册过标记 → 判定为内部
        let internalProvider = NSItemProvider()
        ReorderDrag.register(internalProvider, id: UUID())
        XCTAssertTrue(ReorderDrag.isReorderProvider(internalProvider))

        // 外部文件拖拽（访达等价载荷：public.file-url）→ 判定为外部
        let url = URL(fileURLWithPath: "/tmp/外部文件.txt")
        let fileProvider = NSItemProvider(object: url as NSURL)
        XCTAssertFalse(ReorderDrag.isReorderProvider(fileProvider))

        // 外部文本 / 链接拖拽（曾出现误命中的载荷形态）→ 判定为外部
        let textProvider = NSItemProvider(object: "https://example.com" as NSString)
        XCTAssertFalse(ReorderDrag.isReorderProvider(textProvider))
    }
}
