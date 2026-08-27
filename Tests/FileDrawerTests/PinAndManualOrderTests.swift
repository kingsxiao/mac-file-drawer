import XCTest
@testable import FileDrawer

/// 置顶（免淘汰 + 排前）与手动排序（上移 / 下移 / 移到最前 / 最后）
final class PinAndManualOrderTests: XCTestCase {

    private func item(_ name: String, age: TimeInterval = 0, pinned: Bool = false) -> ShelfItem {
        ShelfItem(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            addedAt: Date(timeIntervalSinceNow: -age),
            pinned: pinned
        )
    }

    // MARK: - 置顶展示

    /// 置顶条目在任何排序模式下都浮到最前；两组内部各按当前排序
    func testPinnedItemsFloatToTopInAllSortModes() {
        MainActor.assumeIsolated {
            let model = InteractionModel()
            // 最旧的是置顶项
            let items = [
                item("甲.txt", age: 300),
                item("乙.txt", age: 200, pinned: true),
                item("丙.txt", age: 100),
            ]
            for mode in InteractionModel.SortMode.allCases {
                model.sortMode = mode
                let displayed = model.displayItems(from: items)
                XCTAssertEqual(displayed.first?.name, "乙.txt", "\(mode.label) 下置顶项应排最前")
                XCTAssertEqual(displayed.count, 3)
            }
        }
    }

    /// 手动顺序：数组顺序即展示顺序（置顶组内同样如此）
    func testManualModeKeepsArrayOrder() {
        MainActor.assumeIsolated {
            let model = InteractionModel()
            model.sortMode = .manual
            let items = [
                item("乙.txt", age: 200),
                item("甲.txt", age: 300),
                item("丙.txt", age: 100),
            ]
            XCTAssertEqual(model.displayItems(from: items).map(\.name), ["乙.txt", "甲.txt", "丙.txt"])
            XCTAssertEqual(InteractionModel.sorted(items, by: .manual).map(\.name), ["乙.txt", "甲.txt", "丙.txt"])
        }
    }

    // MARK: - 置顶免淘汰

    /// 过期清理跳过置顶条目
    func testPrunedKeepsPinnedEvenWhenExpired() {
        let old = item("旧的置顶.txt", age: 10 * 86_400, pinned: true)
        let oldNormal = item("旧的普通.txt", age: 10 * 86_400)
        let kept = ShelfStore.pruned([old, oldNormal, item("新的.txt")], policy: .week)
        XCTAssertEqual(kept.map(\.name), ["旧的置顶.txt", "新的.txt"])
    }

    /// 容量淘汰跳过置顶条目；普通名额按「上限 − 置顶数」计算
    func testTrimmedKeepsPinnedBeyondLimit() {
        // 上限 20：置顶 1 个 + 普通 21 个 → 普通淘汰 2 个最旧的，置顶保留
        var items: [ShelfItem] = [item("置顶.txt", age: 9999, pinned: true)]
        for idx in 0..<21 {
            items.append(item(String(format: "普通%02d.txt", idx), age: TimeInterval(idx) * 100))
        }
        let kept = ShelfStore.trimmed(items, limit: .m20)
        XCTAssertEqual(kept.count, 20)
        XCTAssertEqual(kept.first?.name, "置顶.txt", "最旧的置顶条目不被淘汰")
        XCTAssertEqual(kept.filter(\.pinned).count, 1)
        XCTAssertFalse(kept.contains { $0.name == "普通20.txt" }, "最旧的普通条目被淘汰")
        XCTAssertFalse(kept.contains { $0.name == "普通19.txt" }, "次旧的普通条目被淘汰")
        XCTAssertTrue(kept.contains { $0.name == "普通00.txt" }, "最新的普通条目保留")
    }

    /// 旧版本持久化（无 pinned 字段）解码后默认未置顶；往返保留置顶态
    func testCodablePinnedBackwardCompatibility() throws {
        let legacyJSON = #"{"id":"\#(UUID().uuidString)","path":"/tmp/a.txt","addedAt":1000}"#
        let legacy = try JSONDecoder().decode(ShelfItem.self, from: Data(legacyJSON.utf8))
        XCTAssertFalse(legacy.pinned, "旧格式无 pinned 字段应默认 false")

        let pinnedItem = item("b.txt", pinned: true)
        let data = try JSONEncoder().encode(pinnedItem)
        let decoded = try JSONDecoder().decode(ShelfItem.self, from: data)
        XCTAssertTrue(decoded.pinned)
    }

    // MARK: - 手动排序原语

    func testNudgeMovesItemWithinArray() {
        MainActor.assumeIsolated {
            let store = ShelfStore.shared
            let original = store.items
            store.items = [item("甲.txt"), item("乙.txt"), item("丙.txt")]
            defer { store.items = original }

            store.nudge(ids: [store.items[2].id], by: -1)
            XCTAssertEqual(store.items.map(\.name), ["甲.txt", "丙.txt", "乙.txt"])

            store.nudge(ids: [store.items[0].id], by: -1)
            XCTAssertEqual(store.items.map(\.name), ["甲.txt", "丙.txt", "乙.txt"], "已在顶部不再移动")
        }
    }

    /// 上移跳过置顶分区的邻居：普通条目在置顶条目之下时，上移跨过它而不是挤进置顶区
    func testNudgeSkipsAcrossPinnedPartition() {
        MainActor.assumeIsolated {
            let store = ShelfStore.shared
            let original = store.items
            store.items = [item("置顶甲.txt", pinned: true), item("普通甲.txt"), item("普通乙.txt")]
            defer { store.items = original }

            // 普通乙上移：应跨过置顶甲、与普通甲交换（展示上确实上移一行）
            store.nudge(ids: [store.items[2].id], by: -1)
            XCTAssertEqual(store.items.map(\.name), ["置顶甲.txt", "普通乙.txt", "普通甲.txt"])

            // 普通乙（现在 index 1）再上移：邻居是置顶甲，跳过后越界 → 不动
            store.nudge(ids: [store.items[1].id], by: -1)
            XCTAssertEqual(store.items.map(\.name), ["置顶甲.txt", "普通乙.txt", "普通甲.txt"])
        }
    }

    func testSendMovesBatchKeepingRelativeOrder() {
        MainActor.assumeIsolated {
            let store = ShelfStore.shared
            let original = store.items
            store.items = [item("甲.txt"), item("乙.txt"), item("丙.txt"), item("丁.txt")]
            defer { store.items = original }

            let batch = [store.items[1], store.items[3]]
            store.send(ids: batch.map(\.id), toFront: true)
            XCTAssertEqual(store.items.map(\.name), ["乙.txt", "丁.txt", "甲.txt", "丙.txt"], "整批保持相对顺序移到最前")

            store.send(ids: batch.map(\.id), toFront: false)
            XCTAssertEqual(store.items.map(\.name), ["甲.txt", "丙.txt", "乙.txt", "丁.txt"], "整批移到最后")
        }
    }

    /// 批量置顶语义：有一个未置顶就全部置顶；全已置顶则全部取消
    func testTogglePinnedBatchSemantics() {
        MainActor.assumeIsolated {
            let store = ShelfStore.shared
            let original = store.items
            store.items = [item("甲.txt"), item("乙.txt", pinned: true)]
            defer { store.items = original }

            store.togglePinned(for: store.items)
            XCTAssertTrue(store.items.allSatisfy(\.pinned), "部分置顶 → 全部置顶")

            store.togglePinned(for: store.items)
            XCTAssertTrue(store.items.allSatisfy { !$0.pinned }, "全部已置顶 → 全部取消")
        }
    }
}
