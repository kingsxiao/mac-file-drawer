import XCTest
@testable import FileDrawer

/// 持久化 v3：版本化容器往返与 v1/v2 迁移
final class PersistenceV3Tests: XCTestCase {

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "FileDrawerTests.PersistV3.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    /// v3 往返：置顶/分组归属/当前分组完整保留
    func testV3RoundTripPreservesEverything() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let groupA = DrawerGroup(name: "甲组")
        let groupB = DrawerGroup(name: "乙组")
        let item = ShelfItem(url: URL(fileURLWithPath: "/tmp/v3.txt"), pinned: true, drawerID: groupB.id)
        let schema = ShelfPersistence.Schema(
            version: ShelfPersistence.currentVersion,
            items: [item],
            drawers: [groupA, groupB],
            currentDrawerID: groupB.id
        )
        ShelfPersistence.save(schema, to: defaults)

        let loaded = try XCTUnwrap(ShelfPersistence.load(defaults: defaults))
        XCTAssertEqual(loaded, schema, "v3 往返应无损")
        XCTAssertEqual(loaded.items.first?.pinned, true)
        XCTAssertEqual(loaded.items.first?.drawerID, groupB.id)
    }

    /// v1 迁移：只有旧 items 数组（无 drawerID、无分组 key）→ 默认分组 + 全部归入 + current 为默认
    func testV1Migration() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let legacy = [
            ShelfItem(url: URL(fileURLWithPath: "/tmp/v1-甲.txt")),
            ShelfItem(url: URL(fileURLWithPath: "/tmp/v1-乙.txt")),
        ]
        defaults.set(try JSONEncoder().encode(legacy), forKey: ShelfPersistence.legacyItemsKey)

        let loaded = try XCTUnwrap(ShelfPersistence.load(defaults: defaults))
        XCTAssertEqual(loaded.version, ShelfPersistence.currentVersion)
        XCTAssertEqual(loaded.drawers.map(\.name), ["默认"], "无分组 key 时建默认分组")
        XCTAssertEqual(loaded.currentDrawerID, loaded.drawers[0].id)
        XCTAssertEqual(Set(loaded.items.compactMap(\.drawerID)), [loaded.drawers[0].id], "旧条目全部归入默认分组")
    }

    /// v2 迁移：items 带 drawerID + drawers + current 全保留；current 无效回落第一组
    func testV2MigrationAndInvalidCurrent() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let groupA = DrawerGroup(name: "甲组")
        let groupB = DrawerGroup(name: "乙组")
        let items = [
            ShelfItem(url: URL(fileURLWithPath: "/tmp/v2-甲.txt"), drawerID: groupA.id),
            ShelfItem(url: URL(fileURLWithPath: "/tmp/v2-乙.txt"), drawerID: groupB.id),
        ]
        defaults.set(try JSONEncoder().encode(items), forKey: ShelfPersistence.legacyItemsKey)
        defaults.set(try JSONEncoder().encode([groupA, groupB]), forKey: ShelfPersistence.legacyDrawersKey)
        defaults.set(groupB.id.uuidString, forKey: ShelfPersistence.legacyCurrentDrawerKey)

        let loaded = try XCTUnwrap(ShelfPersistence.load(defaults: defaults))
        XCTAssertEqual(loaded.drawers.map(\.name), ["甲组", "乙组"])
        XCTAssertEqual(loaded.currentDrawerID, groupB.id)
        XCTAssertEqual(loaded.items.filter { $0.drawerID == groupA.id }.count, 1)

        // current 指向不存在的分组 → 回落第一组
        defaults.set(UUID().uuidString, forKey: ShelfPersistence.legacyCurrentDrawerKey)
        let repaired = try XCTUnwrap(ShelfPersistence.load(defaults: defaults))
        XCTAssertEqual(repaired.currentDrawerID, groupA.id, "无效 current 应回落到第一组")
    }

    /// 全新安装（无任何旧数据）→ nil
    func testFreshInstallReturnsNil() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(ShelfPersistence.load(defaults: defaults))
    }

    /// v3 存在时优先于旧布局（旧 key 不再参与）
    func testV3TakesPrecedenceOverLegacy() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let group = DrawerGroup(name: "新分组")
        ShelfPersistence.save(
            .init(version: 3, items: [], drawers: [group], currentDrawerID: group.id),
            to: defaults
        )
        let legacy = [ShelfItem(url: URL(fileURLWithPath: "/tmp/旧.txt"))]
        defaults.set(try JSONEncoder().encode(legacy), forKey: ShelfPersistence.legacyItemsKey)

        let loaded = try XCTUnwrap(ShelfPersistence.load(defaults: defaults))
        XCTAssertEqual(loaded.drawers.map(\.name), ["新分组"], "v3 key 存在时旧布局不应参与")
        XCTAssertTrue(loaded.items.isEmpty)
    }

    /// 容量覆盖并入 v3：schema 字段往返 + 旧独立 key 迁移
    func testDrawerLimitsInSchemaAndLegacyMigration() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let group = DrawerGroup(name: "限数组")
        let schema = ShelfPersistence.Schema(
            version: 3, items: [], drawers: [group], currentDrawerID: group.id,
            drawerLimits: [group.id.uuidString: MaxItemsPolicy.m20.rawValue]
        )
        ShelfPersistence.save(schema, to: defaults)
        let loaded = try XCTUnwrap(ShelfPersistence.load(defaults: defaults))
        XCTAssertEqual(loaded.drawerLimits, [group.id.uuidString: MaxItemsPolicy.m20.rawValue], "limits 随容器往返")

        // 旧独立 key 迁移：v3 key 清掉后 legacyLoad 应从旧 key 恢复（需有 items 才触发 legacy 路径）
        defaults.removeObject(forKey: ShelfPersistence.storeKey)
        let legacyLimits = ["abc": MaxItemsPolicy.m50.rawValue]
        defaults.set(try JSONEncoder().encode(legacyLimits), forKey: ShelfPersistence.legacyDrawerLimitsKey)
        defaults.set(try JSONEncoder().encode([ShelfItem]()), forKey: ShelfPersistence.legacyItemsKey)
        let migrated = try XCTUnwrap(ShelfPersistence.load(defaults: defaults))
        XCTAssertEqual(migrated.drawerLimits, legacyLimits, "旧独立 key 的覆盖并入容器")

        // 旧 v3 数据无 drawerLimits 字段 → 默认空
        let noLimits = try JSONEncoder().encode(
            ShelfPersistence.Schema(version: 3, items: [], drawers: [group], currentDrawerID: group.id, drawerLimits: [:])
        )
        // 手工编码一个缺 drawerLimits 的 JSON 验证解码默认值
        let manual = """
        {"version":3,"items":[],"drawers":[],"currentDrawerID":"\(UUID().uuidString)"}
        """
        let decoded = try JSONDecoder().decode(ShelfPersistence.Schema.self, from: Data(manual.utf8))
        XCTAssertTrue(decoded.drawerLimits.isEmpty, "缺字段解码默认空")
        _ = noLimits
    }
}
