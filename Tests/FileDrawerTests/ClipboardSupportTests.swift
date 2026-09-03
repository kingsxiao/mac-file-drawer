import XCTest
import AppKit
@testable import FileDrawer

/// 剪贴板集成：文件拷贝 / 粘贴读取 / 文本与链接粘贴物化
final class ClipboardSupportTests: XCTestCase {

    /// 独立命名的剪贴板：写入与读取都指向它，不污染系统剪贴板
    private func freshPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("FileDrawerTests.\(UUID().uuidString)"))
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardTests-\(UUID().uuidString)-\(name)")
        try Data("content".utf8).write(to: url)
        return url
    }

    func testFileURLsReadsFileURLsOnly() throws {
        let board = freshPasteboard()
        let file = try makeFile("样本.txt")
        board.clearContents()
        board.writeObjects([file as NSURL])

        XCTAssertEqual(ClipboardSupport.fileURLs(from: board), [file])

        // 纯字符串剪贴板：不读出任何文件 URL
        let textBoard = freshPasteboard()
        textBoard.clearContents()
        textBoard.setString("/tmp/只是路径字符串.txt", forType: .string)
        XCTAssertTrue(ClipboardSupport.fileURLs(from: textBoard).isEmpty)
    }

    func testTextReadsTrimmedString() {
        let board = freshPasteboard()
        board.clearContents()
        board.setString("  hello clipboard \n", forType: .string)
        XCTAssertEqual(ClipboardSupport.text(from: board), "hello clipboard")

        // 空白字符串 → nil
        board.clearContents()
        board.setString("   ", forType: .string)
        XCTAssertNil(ClipboardSupport.text(from: board))

        // 无文本类型 → nil
        let empty = freshPasteboard()
        empty.clearContents()
        empty.setData(Data([0x00]), forType: .png)
        XCTAssertNil(ClipboardSupport.text(from: empty))
    }

    @MainActor
    func testPasteableURLsPrefersFilesOverText() throws {
        let board = freshPasteboard()
        let file = try makeFile("优先.txt")
        board.clearContents()
        board.writeObjects([file as NSURL])
        board.setString("这段文本不应被物化", forType: .string)

        let urls = ClipboardSupport.pasteableURLs(from: board, directory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(urls, [file])
    }

    @MainActor
    func testPasteableURLsMaterializesPlainText() throws {
        let inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardTests-Inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: inbox) }

        let board = freshPasteboard()
        board.clearContents()
        board.setString("剪贴板里的便签内容", forType: .string)

        let urls = ClipboardSupport.pasteableURLs(from: board, directory: inbox)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.pathExtension, "txt")
        XCTAssertEqual(try String(contentsOf: urls.first!, encoding: .utf8), "剪贴板里的便签内容")
    }

    @MainActor
    func testPasteableURLsMaterializesLinkAsWebloc() throws {
        let inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardTests-Inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: inbox) }

        let board = freshPasteboard()
        board.clearContents()
        board.setString("https://example.com/article", forType: .string)

        let urls = ClipboardSupport.pasteableURLs(from: board, directory: inbox)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.pathExtension, "webloc")
    }

    /// 「拷贝图像」→ ⌘V：TIFF 图像数据物化成收件箱图片文件
    @MainActor
    func testPasteableURLsMaterializesImage() throws {
        let inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardTests-Inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: inbox) }

        let board = freshPasteboard()
        let tiff = Data([0x49, 0x49, 0x2A, 0x00])
        board.clearContents()
        board.setData(tiff, forType: .tiff)

        let urls = ClipboardSupport.pasteableURLs(from: board, directory: inbox)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.pathExtension, "tiff")
        XCTAssertEqual(try Data(contentsOf: urls.first!), tiff)
    }

    /// 图像优先于随行文本：部分应用「拷贝图像」时附带图片地址字符串，用户意图是图
    @MainActor
    func testPasteableURLsImageBeatsAccompanyingText() throws {
        let inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardTests-Inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: inbox) }

        let board = freshPasteboard()
        board.clearContents()
        board.declareTypes([.tiff, .string], owner: nil)
        board.setData(Data([0x49, 0x49, 0x2A, 0x00]), forType: .tiff)
        board.setString("https://example.com/photo.jpg", forType: .string)

        let urls = ClipboardSupport.pasteableURLs(from: board, directory: inbox)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.pathExtension, "tiff", "应落图像文件而不是 webloc 链接")
    }

    @MainActor
    func testPasteableURLsEmptyClipboardReturnsEmpty() {
        let board = freshPasteboard()
        board.clearContents()
        XCTAssertTrue(
            ClipboardSupport.pasteableURLs(from: board, directory: FileManager.default.temporaryDirectory).isEmpty
        )
    }

    // MARK: - 拖入管线的顺序保持

    func testDropLoaderKeepsProviderOrder() {
        let a = NSItemProvider(object: "第一条" as NSString)
        let b = NSItemProvider(object: "第二条" as NSString)
        let inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardTests-Drop-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: inbox) }

        let exp = expectation(description: "loadAll completes")
        DropFileLoader.loadAll(from: [a, b], directory: inbox) { urls in
            XCTAssertEqual(urls.count, 2)
            // 各 provider 并发解析，但输出顺序与拖入时一致
            XCTAssertTrue(urls[0].lastPathComponent.contains("第一条"))
            XCTAssertTrue(urls[1].lastPathComponent.contains("第二条"))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }
}
