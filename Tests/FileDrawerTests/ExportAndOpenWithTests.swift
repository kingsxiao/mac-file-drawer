import XCTest
@testable import FileDrawer

/// 导出全部 + 打开方式目录
final class ExportAndOpenWithTests: XCTestCase {

    /// 导出全部：存在的拷贝、失效的跳过、同名自动序号
    func testExportAllCopiesSkipsAndDedupes() throws {
        try MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let dest = dir.appendingPathComponent("导出", isDirectory: true)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

            let store = ShelfStore.shared
            let original = store.items
            try Data("甲".utf8).write(to: dir.appendingPathComponent("甲.txt"))
            try Data("乙".utf8).write(to: dir.appendingPathComponent("乙.txt"))
            try Data("占位".utf8).write(to: dest.appendingPathComponent("甲.txt")) // 制造同名冲突
            store.items = [
                ShelfItem(url: dir.appendingPathComponent("甲.txt")),
                ShelfItem(url: dir.appendingPathComponent("乙.txt")),
                ShelfItem(url: dir.appendingPathComponent("幽灵.txt")), // 不存在
            ]
            defer { store.items = original }

            let result = store.exportAll(to: dest)
            XCTAssertEqual(result.exported, 2)
            XCTAssertEqual(result.skipped, 1)
            XCTAssertEqual(result.failed, 0)

            // 目标里已有同名「甲.txt」→ 新导出落成「甲 2.txt」，原文件不被覆盖
            XCTAssertEqual(
                try String(contentsOf: dest.appendingPathComponent("甲.txt"), encoding: .utf8),
                "占位"
            )
            XCTAssertEqual(
                try String(contentsOf: dest.appendingPathComponent("甲 2.txt"), encoding: .utf8),
                "甲"
            )
            XCTAssertEqual(
                try String(contentsOf: dest.appendingPathComponent("乙.txt"), encoding: .utf8),
                "乙"
            )
        }
    }

    /// .app bundle 显示名去掉扩展名
    func testAppNameStripsAppBundleSuffix() {
        XCTAssertEqual(
            OpenWithCatalog.appName(URL(fileURLWithPath: "/Applications/Safari.app")),
            "Safari"
        )
        XCTAssertEqual(
            OpenWithCatalog.appName(URL(fileURLWithPath: "/Applications/TextEdit.app/Contents/MacOS/TextEdit")),
            "TextEdit"
        )
    }

    /// 文本文件至少有一种打开方式；默认应用排在首位且列表去重
    func testAppsForTextFileIsDedupedWithDefaultFirst() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("打开方式-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let apps = OpenWithCatalog.apps(for: file)
        XCTAssertFalse(apps.isEmpty, "系统至少能为 txt 提供一种打开方式")

        let urls = apps.map(\.url)
        XCTAssertEqual(Set(urls).count, urls.count, "列表应按 URL 去重")

        if let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: file) {
            XCTAssertEqual(urls.first, defaultApp, "默认应用应排在首位")
        }
    }
}
