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

    /// 真实文件引用优先于图像载荷：即使同时注册了图像数据，也不搬进收件箱
    func testProviderWithFileURLBeatsImageData() {
        let fileURL = URL(fileURLWithPath: "/tmp/已有文件.png")
        let provider = NSItemProvider(object: fileURL as NSURL)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { done in
            done(Data([0x89, 0x50]), nil)
            return nil
        }
        XCTAssertEqual(InboxStore.url(fromProvider: provider, directory: inbox), fileURL)
    }

    func testProviderWithUnrecognizedPayloadReturnsNil() {
        let provider = NSItemProvider()
        // 未声明的自定义类型：不在图像 / 视频 / 音频 / PDF 白名单内，也不含 URL / 文本
        provider.registerDataRepresentation(forTypeIdentifier: "com.example.filedrawer-tests.blob", visibility: .all) { done in
            done(Data([0x89]), nil)
            return nil
        }
        XCTAssertNil(InboxStore.url(fromProvider: provider, directory: inbox))
    }

    // MARK: - 媒体载荷物化（浏览器拖图 / 文件承诺）

    /// 浏览器拖图的典型形态：图像数据 + 图片 / 页面 URL 并存——落图本身，不是 webloc
    func testProviderWithImageAndURLMaterializesImageNotWebloc() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let provider = NSItemProvider()
        provider.suggestedName = "海报图.png"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { done in
            done(png, nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { done in
            done(Data("https://example.com/photo".utf8), nil)
            return nil
        }

        let url = try XCTUnwrap(InboxStore.url(fromProvider: provider, directory: inbox))
        XCTAssertEqual(url.pathExtension.lowercased(), "png")
        XCTAssertEqual(try Data(contentsOf: url), png)
        // 名字来自 suggestedName 的主干（去掉扩展名），不是链接命名
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, "海报图")
    }

    /// 只有图像数据（无 URL）同样物化成收件箱图片文件
    func testProviderWithOnlyImageDataMaterializesImage() throws {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.tiff.identifier, visibility: .all) { done in
            done(Data([0x49, 0x49, 0x2A]), nil)
            return nil
        }

        let url = try XCTUnwrap(InboxStore.url(fromProvider: provider, directory: inbox))
        // 两条接收路径的扩展名都可能成立：系统 coerce 的临时文件 .tiff / 数据兜底自写的 .tif
        XCTAssertTrue(["tif", "tiff"].contains(url.pathExtension.lowercased()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// 文件承诺（照片 / 附件拖出的形态）：注册文件表示，loadFileRepresentation 交付文件 → 收进收件箱
    func testProviderWithImageFileRepresentationMaterializesFile() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDrawerPromise-\(UUID().uuidString)-IMG_0001.jpg")
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        try jpeg.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let provider = NSItemProvider()
        provider.suggestedName = "度假 IMG_0001.jpg"
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.jpeg.identifier,
            fileOptions: [],
            visibility: .all
        ) { done in
            done(source, false, nil)
            return nil
        }

        let url = try XCTUnwrap(InboxStore.url(fromProvider: provider, directory: inbox))
        XCTAssertEqual(url.pathExtension.lowercased(), "jpg")
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, "度假 IMG_0001")
        XCTAssertEqual(try Data(contentsOf: url), jpeg)
    }

    /// 非图像的媒体承诺（PDF 附件等）走同一接收路径
    func testProviderWithPDFFileRepresentationMaterializesFile() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDrawerPromise-\(UUID().uuidString)-附件.pdf")
        let pdf = Data("%PDF-1.4 test".utf8)
        try pdf.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.pdf.identifier,
            fileOptions: [],
            visibility: .all
        ) { done in
            done(source, false, nil)
            return nil
        }

        let url = try XCTUnwrap(InboxStore.url(fromProvider: provider, directory: inbox))
        XCTAssertEqual(url.pathExtension.lowercased(), "pdf")
        XCTAssertEqual(try Data(contentsOf: url), pdf)
    }

    /// 类型白名单按 conformance 判定：具体图像 / 视频 / 音频 / PDF 类型命中，未知类型不命中
    func testReceivableFileTypeConformance() {
        XCTAssertTrue(InboxStore.isReceivableFileType(UTType.heic.identifier))
        XCTAssertTrue(InboxStore.isReceivableFileType(UTType.tiff.identifier))
        XCTAssertTrue(InboxStore.isReceivableFileType("public.mpeg-4"))
        XCTAssertTrue(InboxStore.isReceivableFileType(UTType.mp3.identifier))
        XCTAssertTrue(InboxStore.isReceivableFileType(UTType.pdf.identifier))
        XCTAssertFalse(InboxStore.isReceivableFileType(UTType.url.identifier))
        XCTAssertFalse(InboxStore.isReceivableFileType(UTType.utf8PlainText.identifier))
        XCTAssertFalse(InboxStore.isReceivableFileType("com.example.filedrawer-tests.blob"))
        // 拖入类型表 = 原四类 + 媒体白名单
        XCTAssertEqual(
            DropFileLoader.typeIdentifiers.count,
            4 + InboxStore.receivableFileTypeIdentifiers.count
        )
        XCTAssertTrue(DropFileLoader.typeIdentifiers.contains(UTType.image.identifier))
    }
}
