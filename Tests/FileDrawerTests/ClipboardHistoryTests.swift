import XCTest
import AppKit
@testable import FileDrawer

/// 剪贴板历史：捕获优先级 / 查重 / 来源排除 / 容量 / 持久化 / 写回抑制 / 收进抽屉
@MainActor
final class ClipboardHistoryTests: XCTestCase {
    private var defaultsName: String!
    private var defaults: UserDefaults!
    private var settings: AppSettings!
    private var store: ClipboardHistoryStore!
    private var pasteboard: NSPasteboard!
    private var inbox: URL!

    override func setUp() async throws {
        defaultsName = "FileDrawerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)!
        settings = AppSettings(defaults: defaults)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("FileDrawerTests.\(UUID().uuidString)"))
        store = ClipboardHistoryStore(defaults: defaults, settings: settings, pasteboard: pasteboard)
        inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: inbox)
        defaults.removePersistentDomain(forName: defaultsName)
    }

    private func write(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - 捕获优先级（文件 > 图像 > 链接 > 文本）

    func testCaptureTextAsTextPayload() {
        write("普通文本片段")
        XCTAssertTrue(store.capture(from: pasteboard, sourceBundleID: nil, sourceAppName: nil))
        guard case .text(let text)? = store.entries.first?.payload else {
            return XCTFail("应为文本载荷")
        }
        XCTAssertEqual(text, "普通文本片段")
    }

    func testCaptureHTTPTextAsLinkPayload() {
        write("https://example.com/article")
        XCTAssertTrue(store.capture(from: pasteboard, sourceBundleID: nil, sourceAppName: nil))
        guard case .link(let url)? = store.entries.first?.payload else {
            return XCTFail("http(s) 文本应归类为链接")
        }
        XCTAssertEqual(url, "https://example.com/article")
    }

    func testCaptureFilesWinsOverText() throws {
        let file = inbox.appendingPathComponent("样本.txt")
        try "内容".write(to: file, atomically: true, encoding: .utf8)
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        XCTAssertTrue(store.capture(from: pasteboard, sourceBundleID: nil, sourceAppName: nil))
        guard case .files(let paths)? = store.entries.first?.payload else {
            return XCTFail("文件与文本同板时应捕获文件")
        }
        XCTAssertEqual(paths, [file.standardizedFileURL.path])
    }

    func testCaptureImagePayloadWithExtension() {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let tiff = rep.tiffRepresentation!
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        XCTAssertTrue(store.capture(from: pasteboard, sourceBundleID: nil, sourceAppName: nil))
        guard case .image(let data, let ext)? = store.entries.first?.payload else {
            return XCTFail("应为图像载荷")
        }
        XCTAssertEqual(ext, "tiff")
        XCTAssertEqual(data, tiff)
    }

    func testCaptureDropsMissingFilesFromFilesPayload() throws {
        let existing = inbox.appendingPathComponent("存在的.txt")
        try "x".write(to: existing, atomically: true, encoding: .utf8)
        let missing = URL(fileURLWithPath: "/tmp/不存在-\(UUID().uuidString).txt")
        pasteboard.clearContents()
        pasteboard.writeObjects([existing as NSURL, missing as NSURL])
        XCTAssertTrue(store.capture(from: pasteboard, sourceBundleID: nil, sourceAppName: nil))
        guard case .files(let paths)? = store.entries.first?.payload else {
            return XCTFail("应为文件载荷")
        }
        XCTAssertEqual(paths, [existing.standardizedFileURL.path], "失效路径不应进档")
    }

    func testOversizedImageSkipped() {
        // 构造一段「假图像」数据：类型是 tiff，但超过 8MB 上限
        let huge = Data(repeating: 0xFF, count: ClipboardCapture.imageLimit + 1)
        pasteboard.clearContents()
        pasteboard.setData(huge, forType: .tiff)
        XCTAssertFalse(store.capture(from: pasteboard, sourceBundleID: nil, sourceAppName: nil))
    }

    func testLongTextCappedToStorageLimit() {
        let long = String(repeating: "字", count: ClipboardCapture.textLimit + 100)
        write(long)
        XCTAssertTrue(store.capture(from: pasteboard, sourceBundleID: nil, sourceAppName: nil))
        guard case .text(let stored)? = store.entries.first?.payload else {
            return XCTFail("应为文本载荷")
        }
        XCTAssertEqual(stored.count, ClipboardCapture.textLimit)
    }

    // MARK: - 查重与排除

    func testConsecutiveDuplicateSuppressed() {
        XCTAssertTrue(store.insert(payload: .text("同一段"), sourceBundleID: nil, sourceAppName: nil))
        XCTAssertFalse(store.insert(payload: .text("同一段"), sourceBundleID: nil, sourceAppName: nil))
        XCTAssertEqual(store.entries.count, 1)
        // 中间复制了别的内容后，再复制同一段 → 应再次入档
        XCTAssertTrue(store.insert(payload: .text("另一段"), sourceBundleID: nil, sourceAppName: nil))
        XCTAssertTrue(store.insert(payload: .text("同一段"), sourceBundleID: nil, sourceAppName: nil))
        XCTAssertEqual(store.entries.count, 3)
    }

    func testExcludedSourceAppNotRecorded() {
        settings.clipboardExcludedApps = ["com.example.secret"]
        XCTAssertFalse(store.insert(payload: .text("密码"), sourceBundleID: "com.example.secret", sourceAppName: "Secret"))
        XCTAssertTrue(store.insert(payload: .text("正常"), sourceBundleID: "com.example.other", sourceAppName: "Other"))
        XCTAssertEqual(store.entries.count, 1)
    }

    func testDefaultExclusionsIncludePasswordManagers() {
        // 出厂默认排除列表应含钥匙串访问 / 1Password（隐私底线）
        XCTAssertTrue(ClipboardCapture.defaultExcludedBundleIDs.contains("com.apple.keychainaccess"))
        let fresh = AppSettings(defaults: UserDefaults(suiteName: "FileDrawerTests.\(UUID().uuidString)")!)
        XCTAssertTrue(fresh.clipboardExcludedApps.contains("com.1password.1password"))
    }

    // MARK: - 容量与置顶

    func testLimitEvictsOldestUnpinned() {
        settings.clipboardHistoryLimit = .m20
        for index in 0..<25 {
            XCTAssertTrue(store.insert(payload: .text("条目 \(index)"), sourceBundleID: nil, sourceAppName: nil))
        }
        XCTAssertEqual(store.entries.count, 20)
        // 最新 20 条在档（条目 6…24），最旧的 5 条（条目 0…4）被淘汰
        let titles = store.entries.compactMap { entry -> String? in
            if case .text(let text) = entry.payload { return text }
            return nil
        }
        XCTAssertEqual(titles.first, "条目 24")
        XCTAssertFalse(titles.contains("条目 4"))
        XCTAssertTrue(titles.contains("条目 5"))
    }

    func testPinnedExemptFromLimit() {
        settings.clipboardHistoryLimit = .m20
        XCTAssertTrue(store.insert(payload: .text("置顶老条目"), sourceBundleID: nil, sourceAppName: nil))
        store.togglePin(id: store.entries[0].id)
        for index in 0..<25 {
            XCTAssertTrue(store.insert(payload: .text("条目 \(index)"), sourceBundleID: nil, sourceAppName: nil))
        }
        XCTAssertEqual(store.entries.count, 21) // 20 常规 + 1 置顶
        XCTAssertTrue(store.entries.contains { entry in
            if case .text(let text) = entry.payload { return text == "置顶老条目" }
            return false
        })
        // 展示序列置顶在前
        XCTAssertEqual(store.displayedEntries(matching: "").first?.pinned, true)
    }

    func testDisplayedEntriesSearchMatchesContent() {
        store.insert(payload: .text("季度总结报告\n正文内容"), sourceBundleID: nil, sourceAppName: nil)
        store.insert(payload: .text("购物清单"), sourceBundleID: nil, sourceAppName: nil)
        store.insert(payload: .link("https://example.com"), sourceBundleID: nil, sourceAppName: nil)
        XCTAssertEqual(store.displayedEntries(matching: "正文内容").count, 1)
        XCTAssertEqual(store.displayedEntries(matching: "example.com").count, 1)
        XCTAssertEqual(store.displayedEntries(matching: "").count, 3)
    }

    // MARK: - 持久化

    func testPersistenceRoundTrip() {
        store.insert(payload: .text("文本"), sourceBundleID: "com.a", sourceAppName: "A")
        store.insert(payload: .link("https://example.com"), sourceBundleID: nil, sourceAppName: nil)
        store.insert(payload: .files(["/tmp/x.txt"]), sourceBundleID: nil, sourceAppName: nil)
        store.togglePin(id: store.entries[0].id)

        let reloaded = ClipboardHistoryStore(defaults: defaults, settings: settings, pasteboard: pasteboard)
        XCTAssertEqual(reloaded.entries, store.entries)
        XCTAssertEqual(reloaded.entries.first?.pinned, true)
    }

    // MARK: - 写回抑制（copyBack 不回声入档）

    func testCopyBackDoesNotReEnterHistory() {
        store.setMonitoring(true)
        store.insert(payload: .text("要写回的文本"), sourceBundleID: nil, sourceAppName: nil)
        XCTAssertEqual(store.entries.count, 1)
        // 写回：粘贴板 changeCount 变化，但被记为自发，下一轮轮询不回声入档
        store.copyBack(store.entries[0])
        XCTAssertEqual(pasteboard.string(forType: .string), "要写回的文本")
        store.tick()
        XCTAssertEqual(store.entries.count, 1, "写回自身不应再次入档")
        // 其他来源再复制 → 正常入档
        write("别人的复制")
        store.tick()
        XCTAssertEqual(store.entries.count, 2)
    }

    // MARK: - 收进抽屉

    func testAdoptTextMaterializesIntoInbox() throws {
        let shelf = ShelfStore.shared
        let original = shelf.items
        defer { shelf.items = original }

        store.insert(payload: .text("收进抽屉的文本"), sourceBundleID: nil, sourceAppName: nil)
        let entry = store.entries[0]
        let result = store.adopt(entry, into: shelf, directory: inbox)
        XCTAssertEqual(result.added, 1)
        let item = try XCTUnwrap(shelf.items.first { $0.path.hasPrefix(inbox.path) })
        XCTAssertEqual(item.name, "收进抽屉的文本.txt")
        XCTAssertEqual(try String(contentsOf: item.url, encoding: .utf8), "收进抽屉的文本")
    }

    func testAdoptLinkMaterializesWebloc() throws {
        let shelf = ShelfStore.shared
        let original = shelf.items
        defer { shelf.items = original }

        store.insert(payload: .link("https://example.com/page"), sourceBundleID: nil, sourceAppName: nil)
        let result = store.adopt(store.entries[0], into: shelf, directory: inbox)
        XCTAssertEqual(result.added, 1)
        let item = try XCTUnwrap(shelf.items.first { $0.path.hasPrefix(inbox.path) })
        XCTAssertEqual(item.url.pathExtension, "webloc")
    }

    func testAdoptImageMaterializesFile() throws {
        let shelf = ShelfStore.shared
        let original = shelf.items
        defer { shelf.items = original }

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        store.insert(payload: .image(rep.tiffRepresentation!, ext: "tiff"), sourceBundleID: nil, sourceAppName: nil)
        let result = store.adopt(store.entries[0], into: shelf, directory: inbox)
        XCTAssertEqual(result.added, 1)
        let item = try XCTUnwrap(shelf.items.first { $0.path.hasPrefix(inbox.path) })
        XCTAssertEqual(item.url.pathExtension, "tiff")
    }

    func testAdoptFilesAddsExistingAndReportsInvalid() throws {
        let shelf = ShelfStore.shared
        let original = shelf.items
        defer { shelf.items = original }

        let file = inbox.appendingPathComponent("存在的.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        store.insert(
            payload: .files([file.standardizedFileURL.path, "/tmp/不存在的-\(UUID().uuidString).txt"]),
            sourceBundleID: nil, sourceAppName: nil
        )
        let result = store.adopt(store.entries[0], into: shelf, directory: inbox)
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.invalid, 1)
        // 同一批里有效文件已入列；重复收进 → 报重复
        let second = store.adopt(store.entries[0], into: shelf, directory: inbox)
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.skippedDuplicates, 1)
    }

    // MARK: - 监控 tick（驱动真实轮询路径）

    func testTickCapturesPasteboardChangeOnce() {
        store.setMonitoring(true)
        write("轮询捕获")
        store.tick()
        XCTAssertEqual(store.entries.count, 1)
        store.tick() // changeCount 未变 → 不重复入档
        XCTAssertEqual(store.entries.count, 1)
    }

    // MARK: - 编解码与标题

    func testPayloadCodableRoundTrip() throws {
        let entry = ClipboardEntry(payload: .image(Data([1, 2, 3]), ext: "png"), pinned: true)
        let data = try JSONEncoder().encode([entry])
        let decoded = try JSONDecoder().decode([ClipboardEntry].self, from: data)
        XCTAssertEqual(decoded, [entry])
    }

    func testTitleHelpers() {
        XCTAssertEqual(ClipboardCapture.title(of: .link("https://www.example.com/a/b")), "example.com")
        XCTAssertEqual(ClipboardCapture.title(of: .text("第一行\n第二行")), "第一行")
        XCTAssertEqual(
            ClipboardCapture.title(of: .files(["/tmp/报告.pdf", "/tmp/其他.pdf"])),
            L10n.tf("%@ 等 %d 个文件", "报告.pdf", 2)
        )
    }

    // MARK: - 历史视图键盘集（↑↓ 选中锚点 / 搜索状态上移）

    /// 无锚点 ↓ 选第一条、↑ 选最后一条；边界夹紧（与条目列表 moveSelection 同构）
    func testMoveSelectionFromScratchAndClamp() {
        store.insert(payload: .text("第一条"), sourceBundleID: nil, sourceAppName: nil)
        store.insert(payload: .text("第二条"), sourceBundleID: nil, sourceAppName: nil)
        store.insert(payload: .text("第三条"), sourceBundleID: nil, sourceAppName: nil)

        store.moveSelection(by: 1, matching: "")
        XCTAssertEqual(store.selectedEntryID, store.entries.first?.id, "无锚点 ↓ 应选第一条（展示首行）")

        store.moveSelection(by: 1, matching: "")
        XCTAssertEqual(store.selectedEntryID, store.entries[1].id)

        store.moveSelection(by: -5, matching: "")
        XCTAssertEqual(store.selectedEntryID, store.entries.first?.id, "向上越界应夹在第一条")

        store.moveSelection(by: 5, matching: "")
        XCTAssertEqual(store.selectedEntryID, store.entries.last?.id, "向下越界应夹在最后一条")

        store.selectedEntryID = nil
        store.moveSelection(by: -1, matching: "")
        XCTAssertEqual(store.selectedEntryID, store.entries.last?.id, "无锚点 ↑ 应选最后一条")
    }

    /// 选中移动尊重当前搜索过滤：只在匹配序列内移动；锚点被过滤掉时从头计位
    func testMoveSelectionRespectsSearchQuery() {
        store.insert(payload: .text("季度报告甲"), sourceBundleID: nil, sourceAppName: nil)
        store.insert(payload: .text("购物清单乙"), sourceBundleID: nil, sourceAppName: nil)
        store.insert(payload: .text("季度总结丙"), sourceBundleID: nil, sourceAppName: nil)

        store.searchText = "季度"
        store.moveSelection(by: 1, matching: store.searchText)
        let firstMatch = store.displayedEntries(matching: store.searchText).first
        XCTAssertEqual(store.selectedEntryID, firstMatch?.id, "搜索下 ↓ 应选首个匹配")

        store.moveSelection(by: 1, matching: store.searchText)
        XCTAssertEqual(
            store.selectedEntryID,
            store.displayedEntries(matching: store.searchText).last?.id,
            "搜索序列只有两条：再 ↓ 应到末位"
        )

        // 锚点指向被过滤掉的条目时，按方向从头计位（KeyboardRouter 的 Delete 轮播
        // 依赖 displayed 序列，视图层 onChange(searchText) 负责收回失配锚点）
        store.searchText = "购物"
        store.moveSelection(by: 1, matching: store.searchText)
        XCTAssertEqual(store.selectedEntryID, store.entries[1].id)
    }

    /// 空结果集上移动选中：锚点收回，不崩溃
    func testMoveSelectionOnEmptyDisplayClearsAnchor() {
        store.insert(payload: .text("唯一"), sourceBundleID: nil, sourceAppName: nil)
        store.searchText = "不存在的关键词"
        store.selectedEntryID = store.entries[0].id
        store.moveSelection(by: 1, matching: store.searchText)
        XCTAssertNil(store.selectedEntryID, "过滤后列表为空应收回锚点")
    }

    /// 锚点随列表回收：删除 / 清空后指向失效条目即置 nil
    func testSelectedAnchorReclaimedOnRemovalAndClear() {
        store.insert(payload: .text("甲"), sourceBundleID: nil, sourceAppName: nil)
        store.insert(payload: .text("乙"), sourceBundleID: nil, sourceAppName: nil)
        store.selectedEntryID = store.entries[0].id

        store.removeEntry(id: store.entries[0].id)
        XCTAssertNil(store.selectedEntryID, "删除锚点条目后应收回锚点")

        store.selectedEntryID = store.entries[0].id
        store.clear()
        XCTAssertNil(store.selectedEntryID, "清空后应收回锚点")
    }

    /// 收进抽屉 + 反馈共用入口：三种结果分别给出对应轻提示文案
    func testAdoptWithFeedbackPostsNotices() throws {
        let shelf = ShelfStore.shared
        let original = shelf.items
        defer { shelf.items = original }

        // 文本载荷：物化成功 → 「已收进」
        store.insert(payload: .text("待收进文本"), sourceBundleID: nil, sourceAppName: nil)
        store.adopt(store.entries[0], withFeedbackIn: shelf)
        XCTAssertEqual(shelf.notice, L10n.tf("已收进「%@」", "待收进文本"), "成功收进应提示标题")

        // 文件载荷：同一路径第二次收进 → 「抽屉里已有该条目」（文本每次物化新文件不触发）
        let file = inbox.appendingPathComponent("重复样本.txt")
        try "内容".write(to: file, atomically: true, encoding: .utf8)
        store.insert(payload: .files([file.path]), sourceBundleID: nil, sourceAppName: nil)
        store.adopt(store.entries[0], withFeedbackIn: shelf)
        XCTAssertEqual(shelf.notice, L10n.tf("已收进「%@」", "重复样本.txt"))
        store.adopt(store.entries[0], withFeedbackIn: shelf)
        XCTAssertEqual(shelf.notice, L10n.t("抽屉里已有该条目"), "同路径再收进应提示已存在")

        // 路径已不存在 → 「内容已失效」
        store.insert(payload: .files(["/tmp/不存在-\(UUID().uuidString).pdf"]), sourceBundleID: nil, sourceAppName: nil)
        store.adopt(store.entries[0], withFeedbackIn: shelf)
        XCTAssertEqual(shelf.notice, L10n.t("内容已失效，未能收进抽屉"), "失效载荷应提示未收进")
    }
}
