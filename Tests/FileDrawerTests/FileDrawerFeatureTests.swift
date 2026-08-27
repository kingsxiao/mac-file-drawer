import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import FileDrawer

/// 拖拽管道往返一致性 + 搜索/排序引擎的行为契约（XCTest 运行器）
final class FileDrawerFeatureTests: XCTestCase {

    // MARK: - 拖拽往返

    @MainActor
    func testDragProviderRoundTripRestoresSameFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("往返测试样本.txt")
        try Data("roundtrip".utf8).write(to: fileURL)

        let item = ShelfItem(url: fileURL)
        let provider = item.dragProvider()

        XCTAssertTrue(provider.suggestedName == fileURL.lastPathComponent)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))

        let loaded = waitForURLs { DropFileLoader.loadAll(from: [provider], completion: $0) }

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.standardizedFileURL, fileURL.standardizedFileURL)
    }

    @MainActor
    func testMultipleProvidersResolveTogether() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var providers = [NSItemProvider]()
        var expected = Set<URL>()
        for idx in 0..<3 {
            let url = dir.appendingPathComponent("样本\(idx).txt")
            try Data("x\(idx)".utf8).write(to: url)
            providers.append(ShelfItem(url: url).dragProvider())
            expected.insert(url.standardizedFileURL)
        }

        let loaded = waitForURLs { DropFileLoader.loadAll(from: providers, completion: $0) }
        XCTAssertEqual(Set(loaded.map(\.standardizedFileURL)), expected)
    }

    private func waitForURLs(_ run: (@escaping ([URL]) -> Void) -> Void) -> [URL] {
        let expectation = expectation(description: "urls loaded")
        var result = [URL]()
        run { urls in
            result = urls
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        return result
    }

    // MARK: - 大小与元信息

    func testSizeTextFormatting() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        try Data(repeating: 0, count: 2048).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(ShelfStore.sizeText(for: url.path), "2 KB")

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt"))
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(ShelfStore.sizeText(for: folder.path), "1 个项目")
    }

    // MARK: - 搜索 / 排序引擎

    private func makeItems() -> [ShelfItem] {
        [
            ShelfItem(url: URL(fileURLWithPath: "/tmp/风景照片.jpg"), addedAt: Date(timeIntervalSince1970: 1000)),
            ShelfItem(url: URL(fileURLWithPath: "/tmp/main.swift"), addedAt: Date(timeIntervalSince1970: 3000)),
            ShelfItem(url: URL(fileURLWithPath: "/tmp/Swift方案.pdf"), addedAt: Date(timeIntervalSince1970: 2000)),
        ]
    }

    func testEmptyQueryReturnsAll() {
        let items = makeItems()
        XCTAssertEqual(InteractionModel.filter(items, query: ""), items)
        XCTAssertEqual(InteractionModel.filter(items, query: "   "), items)
    }

    func testCaseInsensitiveMatch() {
        let hits = InteractionModel.filter(makeItems(), query: "swift")
        // filter 保持原有顺序
        XCTAssertEqual(hits.map(\.name), ["main.swift", "Swift方案.pdf"])
    }

    func testNoHitsReturnsEmpty() {
        XCTAssertTrue(InteractionModel.filter(makeItems(), query: "不存在").isEmpty)
    }

    func testTimeOrdering() {
        let items = makeItems()
        XCTAssertEqual(
            InteractionModel.sorted(items, by: .timeNewestFirst).map(\.name),
            ["main.swift", "Swift方案.pdf", "风景照片.jpg"]
        )
        XCTAssertEqual(
            InteractionModel.sorted(items, by: .timeOldestFirst).map(\.name),
            ["风景照片.jpg", "Swift方案.pdf", "main.swift"]
        )
    }

    func testNameOrderingNaturalSort() {
        let names = ["b.txt", "a10.txt", "a2.txt"]
        let items = names.map { ShelfItem(url: URL(fileURLWithPath: "/tmp/\($0)"), addedAt: .distantPast) }
        // 自然排序：a2 在 a10 之前
        XCTAssertEqual(
            InteractionModel.sorted(items, by: .nameAscending).map(\.name),
            ["a2.txt", "a10.txt", "b.txt"]
        )
    }

    func testKindGroupingFoldersFirst() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("甲文件夹", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let folder = ShelfItem(url: dir, addedAt: .distantPast)
        let doc = ShelfItem(url: URL(fileURLWithPath: "/tmp/zeta.pdf"), addedAt: .distantPast)
        let img = ShelfItem(url: URL(fileURLWithPath: "/tmp/alpha.png"), addedAt: .distantPast)

        XCTAssertEqual(
            InteractionModel.sorted([img, doc, folder], by: .kindThenName).map(\.name),
            ["甲文件夹", "zeta.pdf", "alpha.png"]
        )
    }

    func testDisplayPipelineFiltersThenSorts() {
        // 该环境的 xctest 辅助器在 @MainActor 测试方法上会段错误，改为主线程假定隔离执行
        MainActor.assumeIsolated {
            let model = InteractionModel()
            model.searchText = "swift"
            XCTAssertEqual(
                model.displayItems(from: makeItems()).map(\.name),
                ["main.swift", "Swift方案.pdf"]
            )
        }
    }

    func testSelectionClampsWithinBounds() {
        MainActor.assumeIsolated {
            let model = InteractionModel()
            let items = makeItems()

            XCTAssertNil(model.selectedItem(in: items)) // 初始未选中
            model.moveSelection(by: 1, within: items)
            XCTAssertEqual(model.selectedID, items.first?.id)

            model.selectedID = items.last?.id
            model.moveSelection(by: 1, within: items) // 已到末尾，应保持不变
            XCTAssertEqual(model.selectedID, items.last?.id)

            model.moveSelection(by: -1, within: items)
            XCTAssertEqual(model.selectedID?.uuidString, items[1].id.uuidString)
        }
    }
}
