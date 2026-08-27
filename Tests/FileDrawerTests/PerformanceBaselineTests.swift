import XCTest
import AppKit
@testable import FileDrawer

/// 性能度量基线：持久化编码 / 展示管线 / 缓存指纹与 IO / 按组淘汰。
/// measure 记录基线供回归对比；末尾的宽上界断言防极端回归（CI 机器波动留足余量）。
final class PerformanceBaselineTests: XCTestCase {

    private func syntheticItems(_ count: Int, drawers: Int) -> [ShelfItem] {
        let drawerIDs = (0..<drawers).map { _ in UUID() }
        return (0..<count).map { idx in
            ShelfItem(
                url: URL(fileURLWithPath: "/tmp/基准样本/\(idx % 7 == 0 ? "图片" : "文档")-\(idx).\(idx % 7 == 0 ? "jpg" : "pdf")"),
                addedAt: Date(timeIntervalSinceNow: -Double(idx)),
                pinned: idx % 23 == 0,
                drawerID: drawerIDs[idx % drawers]
            )
        }
    }

    // MARK: - 持久化编码 / 解码

    /// 1000 条目（约 5 分组）全量 JSON 编码 + 解码往返
    func testPersistenceEncodeDecodeBaseline() throws {
        let items = syntheticItems(1000, drawers: 5)
        let encoder = JSONEncoder()

        var decoded: [ShelfItem] = []
        measure {
            let data = try! encoder.encode(items)
            decoded = try! JSONDecoder().decode([ShelfItem].self, from: data)
        }
        XCTAssertEqual(decoded.count, 1000)

        // 宽上界：单次往返不应超过 2 秒（正常量级为几十毫秒）
        let start = Date()
        let data = try encoder.encode(items)
        _ = try JSONDecoder().decode([ShelfItem].self, from: data)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "编码+解码 1000 条目应远快于 2 秒（实际数据量 \((data.count / 1024))KB）")
    }

    // MARK: - 展示管线（过滤 + 置顶分区 + 排序）

    /// 500 条目带关键字与 kind: 语法的完整展示管线
    func testDisplayPipelineBaseline() {
        MainActor.assumeIsolated {
            let model = InteractionModel()
            let items = syntheticItems(500, drawers: 3)

            model.searchText = "文档 kind:pdf 7"
            var output: [ShelfItem] = []
            measure {
                output = model.displayItems(from: items, sort: .nameAscending)
            }
            XCTAssertFalse(output.isEmpty, "「文档-7.pdf / 文档-17.pdf…」应命中")

            // 宽上界：一次管线 < 0.5 秒（正常为毫秒级）
            let start = Date()
            _ = model.displayItems(from: items, sort: .nameAscending)
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        }
    }

    // MARK: - 缩略图缓存指纹

    /// 1000 次指纹键计算（SHA-256）
    func testThumbnailKeyBaseline() {
        measure {
            for idx in 0..<1000 {
                _ = ThumbnailDiskCache.makeKey(path: "/tmp/基准\(idx).jpg", modifiedAt: 1_000_000, fileSize: idx)
            }
        }
        let start = Date()
        for idx in 0..<1000 {
            _ = ThumbnailDiskCache.makeKey(path: "/tmp/基准\(idx).jpg", modifiedAt: 1_000_000, fileSize: idx)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "1000 次键计算应远快于 1 秒")
    }

    // MARK: - 按组容量淘汰

    /// 500 条目 × 5 分组的按组淘汰
    func testPerDrawerTrimBaseline() {
        let items = syntheticItems(500, drawers: 5)
        measure {
            _ = ShelfStore.trimmedPerDrawer(items) { _ in .m100 }
        }
        let start = Date()
        _ = ShelfStore.trimmedPerDrawer(items) { _ in .m100 }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    // MARK: - 防抖落盘行为（正确性，非性能）

    /// flushPersist 立即写盘；persist 防抖不阻塞
    func testFlushPersistWritesImmediately() throws {
        MainActor.assumeIsolated {
            let store = ShelfStore.shared
            let original = store.items
            let originalData = UserDefaults.standard.data(forKey: ShelfPersistence.storeKey)

            let probe = [ShelfItem(url: URL(fileURLWithPath: "/tmp/防抖探针-\(UUID().uuidString).txt"))]
            store.items = probe // didSet → 防抖
            defer {
                store.items = original
                store.flushPersist()
                if let originalData {
                    UserDefaults.standard.set(originalData, forKey: ShelfPersistence.storeKey)
                }
            }

            store.flushPersist() // 立即落盘
            let saved = UserDefaults.standard.data(forKey: ShelfPersistence.storeKey)
            XCTAssertNotNil(saved)
            let decoded = try? JSONDecoder().decode(ShelfPersistence.Schema.self, from: saved ?? Data())
            XCTAssertEqual(decoded?.items.first?.name, probe[0].name, "flush 后 v3 容器应立即可读")
        }
    }
}
