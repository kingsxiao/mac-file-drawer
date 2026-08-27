import XCTest
import UniformTypeIdentifiers
@testable import FileDrawer

/// 收件箱：拖入文本 / 链接物化成真实文件（命名 / 去重 / webloc 生成 / 清扫）
final class InboxStoreTests: XCTestCase {
    private var inbox: URL!

    override func setUpWithError() throws {
        inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDrawerInboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: inbox)
    }

    // MARK: - 命名（纯函数）

    func testSnippetNameForTextUsesFirstLine() {
        XCTAssertEqual(InboxStore.snippetName(forText: "第一行标题\n第二行内容"), "第一行标题")
        // 空白行会被跳过，取第一行有内容的行
        XCTAssertEqual(InboxStore.snippetName(forText: "\n   \n  会议记录：\n正文"), "会议记录：")
        // 空文本回退默认名
        XCTAssertEqual(InboxStore.snippetName(forText: "  \n \n"), "文本片段")
    }

    func testSnippetNameSanitizesIllegalCharacters() {
        let name = InboxStore.snippetName(forText: "a/b\\c:d*e?f\"g<h>i|j")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains("|"))
        XCTAssertTrue(name.hasPrefix("a"))
    }

    func testSnippetNameCapsLength() {
        let long = String(repeating: "长", count: 120)
        let name = InboxStore.snippetName(forText: long)
        XCTAssertLessThanOrEqual(name.count, 40)
    }

    func testSnippetNameForURLCombinesHostAndTail() {
        let url = URL(string: "https://www.example.com/articles/2026/summary.html")!
        XCTAssertEqual(InboxStore.snippetName(forURL: url), "example.com summary.html")
    }

    func testSnippetNameForURLFallsBackToHost() {
        XCTAssertEqual(InboxStore.snippetName(forURL: URL(string: "https://example.com")!), "example.com")
        XCTAssertEqual(InboxStore.snippetName(forURL: URL(string: "https://example.com/")!), "example.com")
    }

    func testSanitizeCollapsesWhitespaceAndTrimsDots() {
        XCTAssertEqual(InboxStore.sanitize("  hello   world  ", maxLength: 40), "hello world")
        XCTAssertEqual(InboxStore.sanitize("... trailing dots ...", maxLength: 40), "trailing dots")
        XCTAssertNil(InboxStore.sanitize("   ", maxLength: 40))
        XCTAssertNil(InboxStore.sanitize("", maxLength: 40))
    }

    // MARK: - 物化

    func testMaterializeTextWritesFileWithContent() throws {
        let url = try XCTUnwrap(InboxStore.materialize(text: "整段\n文本", directory: inbox))
        XCTAssertEqual(url.pathExtension, "txt")
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, "整段")
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(content, "整段\n文本")
    }

    func testMaterializeURLWritesValidWebloc() throws {
        let link = URL(string: "https://example.com/page")!
        let url = try XCTUnwrap(InboxStore.materialize(url: link, directory: inbox))
        XCTAssertEqual(url.pathExtension, "webloc")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        )
        XCTAssertEqual(plist["URL"], "https://example.com/page")
    }

    func testUniqueChildURLDeduplicates() throws {
        FileManager.default.createFile(
            atPath: inbox.appendingPathComponent("名字.txt").path, contents: Data()
        )
        let second = InboxStore.uniqueChildURL(name: "名字", ext: "txt", directory: inbox)
        XCTAssertEqual(second.deletingPathExtension().lastPathComponent, "名字 2")
        FileManager.default.createFile(atPath: second.path, contents: Data())
        let third = InboxStore.uniqueChildURL(name: "名字", ext: "txt", directory: inbox)
        XCTAssertEqual(third.deletingPathExtension().lastPathComponent, "名字 3")
    }

    func testIsManaged() {
        let managed = inbox.appendingPathComponent("x.txt")
        XCTAssertTrue(InboxStore.isManaged(managed.standardizedFileURL.path, directory: inbox))
        XCTAssertFalse(InboxStore.isManaged("/tmp/外部文件.txt", directory: inbox))
        // 前缀相似但不在目录内
        XCTAssertFalse(InboxStore.isManaged(inbox.path + "-sibling/x.txt", directory: inbox))
    }

    // MARK: - 清扫

    func testSweepDeletesUnreferencedKeepsReferenced() throws {
        let kept = inbox.appendingPathComponent("保留.txt")
        let gone = inbox.appendingPathComponent("丢弃.txt")
        try "k".write(to: kept, atomically: true, encoding: .utf8)
        try "g".write(to: gone, atomically: true, encoding: .utf8)

        InboxStore.sweep(referenced: [kept.standardizedFileURL.path], directory: inbox)

        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))
    }

    // MARK: - Provider 解析

    func testProviderWithPlainTextMaterializesTextFile() throws {
        let provider = NSItemProvider(object: "一段拖入的文本" as NSString)
        let url = try XCTUnwrap(InboxStore.url(fromProvider: provider, directory: inbox))
        XCTAssertEqual(url.pathExtension, "txt")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "一段拖入的文本")
    }

    func testProviderWithPlainTextLinkMaterializesWebloc() throws {
        let provider = NSItemProvider(object: "https://example.com/post/1" as NSString)
        let url = try XCTUnwrap(InboxStore.url(fromProvider: provider, directory: inbox))
        XCTAssertEqual(url.pathExtension, "webloc")
    }

    func testProviderWithWebURLMaterializesWebloc() throws {
        let provider = NSItemProvider(object: URL(string: "https://example.com")! as NSURL)
        let url = try XCTUnwrap(InboxStore.url(fromProvider: provider, directory: inbox))
        XCTAssertEqual(url.pathExtension, "webloc")
    }

    func testProviderWithFileURLPassesThrough() {
        let fileURL = URL(fileURLWithPath: "/tmp/已有文件.png")
        let provider = NSItemProvider(object: fileURL as NSURL)
        let url = InboxStore.url(fromProvider: provider, directory: inbox)
        XCTAssertEqual(url, fileURL)
    }

    func testProviderWithUnrecognizedPayloadReturnsNil() {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { done in
            done(Data([0x89]), nil)
            return nil
        }
        XCTAssertNil(InboxStore.url(fromProvider: provider, directory: inbox))
    }
}
