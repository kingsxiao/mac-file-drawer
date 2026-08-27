import XCTest
import AppKit
@testable import FileDrawer

/// 市场调研后补全的设置与暂存维护逻辑：自动清理 / 容量上限 / 元信息组合 / 新设置持久化
final class ShelfMaintenanceTests: XCTestCase {

    private func makeDefaults() -> (defaults: UserDefaults, name: String) {
        let name = "FileDrawerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, name)
    }

    private func item(_ name: String, ageDays: Double) -> ShelfItem {
        ShelfItem(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            addedAt: Date(timeIntervalSinceNow: -ageDays * 86_400)
        )
    }

    // MARK: - 过期自动清理

    func testPruneKeepsRecentAndDropsExpired() {
        let fresh = item("新.txt", ageDays: 0.5)
        let old = item("旧.txt", ageDays: 3)

        XCTAssertEqual(ShelfStore.pruned([fresh, old], policy: .off).count, 2)
        XCTAssertEqual(ShelfStore.pruned([fresh, old], policy: .oneDay), [fresh])
        XCTAssertEqual(ShelfStore.pruned([fresh, old], policy: .week).count, 2)

        // 30 天策略下 3 天的条目仍在
        XCTAssertEqual(ShelfStore.pruned([old], policy: .month), [old])
        // 7 天策略下 3 天的条目仍在
        XCTAssertEqual(ShelfStore.pruned([old], policy: .week), [old])
        // 1 天策略下 3 天的条目被清
        XCTAssertTrue(ShelfStore.pruned([old], policy: .oneDay).isEmpty)
    }

    func testPruneBoundaryIsInclusive() {
        // 注入固定的 now，消除构造与调用之间的毫秒差
        let now = Date()
        // 恰好 1 天前的条目在「1 天后」策略下应被保留（>= 截止时间）
        let edge = ShelfItem(
            url: URL(fileURLWithPath: "/tmp/边界.txt"),
            addedAt: now.addingTimeInterval(-86_400)
        )
        XCTAssertEqual(ShelfStore.pruned([edge], policy: .oneDay, now: now), [edge])
        // 多 1 秒即被清理
        let older = ShelfItem(
            url: URL(fileURLWithPath: "/tmp/超界.txt"),
            addedAt: now.addingTimeInterval(-86_401)
        )
        XCTAssertTrue(ShelfStore.pruned([older], policy: .oneDay, now: now).isEmpty)
    }

    // MARK: - 容量上限

    func testTrimDropsOldestAndKeepsOriginalOrder() {
        // 21 个条目、按加入时间从旧到新排列
        let items = (0..<21).map { item(String(format: "f%02d.txt", $0), ageDays: Double(21 - $0)) }

        // 不限制 / 未超限：原样返回
        XCTAssertEqual(ShelfStore.trimmed(items, limit: .unlimited), items)

        // 超限（21 > 20）：淘汰最早的 f00，其余保持原相对顺序
        let trimmed = ShelfStore.trimmed(items, limit: .m20)
        XCTAssertEqual(trimmed.count, 20)
        XCTAssertEqual(trimmed.first?.name, "f01.txt")
        XCTAssertEqual(trimmed.last?.name, "f20.txt")
        XCTAssertEqual(trimmed, Array(items.dropFirst()))

        // 空列表 / 单条不越界
        XCTAssertTrue(ShelfStore.trimmed([], limit: .m20).isEmpty)
        XCTAssertEqual(ShelfStore.trimmed([items[0]], limit: .m20).count, 1)
    }

    // MARK: - 元信息组合

    func testMetaLineRespectsDisplaySettings() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        try Data(repeating: 0, count: 2048).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        MainActor.assumeIsolated {
            let settings = AppSettings(defaults: defaults)
            let shelfItem = ShelfItem(url: url)

            // 默认：大小 · 时间 两段
            let full = shelfItem.metaLine(settings: settings)
            XCTAssertTrue(full.contains("2 KB"))
            XCTAssertTrue(full.contains("·"))

            // 只显示大小
            settings.showAddedTime = false
            XCTAssertEqual(shelfItem.metaLine(settings: settings), "2 KB")

            // 全部关闭：空串（行内隐藏元信息）
            settings.showFileSize = false
            XCTAssertEqual(shelfItem.metaLine(settings: settings), "")
        }
    }

    // MARK: - 新设置默认值与持久化

    func testNewSettingsDefaultsAndRoundTrip() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        MainActor.assumeIsolated {
            let s = AppSettings(defaults: defaults)
            // 默认值
            XCTAssertFalse(s.openOnSingleClick)
            XCTAssertFalse(s.collapseAfterDragOut)
            XCTAssertFalse(s.collapseWhenEmpty)
            XCTAssertTrue(s.showFileSize)
            XCTAssertTrue(s.showAddedTime)
            XCTAssertFalse(s.compactRows)
            XCTAssertEqual(s.autoClean, .off)
            XCTAssertEqual(s.maxItems, .unlimited)
            XCTAssertEqual(s.material, .ultraThin)
            XCTAssertEqual(s.edge, .right)

            // 写入
            s.openOnSingleClick = true
            s.collapseAfterDragOut = true
            s.collapseWhenEmpty = true
            s.showFileSize = false
            s.showAddedTime = false
            s.compactRows = true
            s.autoClean = .week
            s.maxItems = .m50
            s.material = .thick
            s.edge = .left

            let reloaded = AppSettings(defaults: defaults)
            XCTAssertTrue(reloaded.openOnSingleClick)
            XCTAssertTrue(reloaded.collapseAfterDragOut)
            XCTAssertTrue(reloaded.collapseWhenEmpty)
            XCTAssertFalse(reloaded.showFileSize)
            XCTAssertFalse(reloaded.showAddedTime)
            XCTAssertTrue(reloaded.compactRows)
            XCTAssertEqual(reloaded.autoClean, .week)
            XCTAssertEqual(reloaded.autoClean.days, 7)
            XCTAssertEqual(reloaded.maxItems, .m50)
            XCTAssertEqual(reloaded.maxItems.count, 50)
            XCTAssertEqual(reloaded.material, .thick)
            XCTAssertEqual(reloaded.edge, .left)
        }
    }

    func testPolicyCatalogs() {
        XCTAssertEqual(AutoCleanPolicy.allCases.map(\.days), [nil, 1, 7, 30])
        XCTAssertEqual(MaxItemsPolicy.allCases.map(\.count), [nil, 20, 50, 100])
        XCTAssertEqual(DrawerMaterial.allCases.count, 4)
        XCTAssertEqual(DrawerEdge.allCases.count, 2)
    }
}
