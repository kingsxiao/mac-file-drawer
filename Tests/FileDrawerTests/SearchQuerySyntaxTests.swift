import XCTest
@testable import FileDrawer

/// 搜索语法：kind: 类型过滤 + 多关键字交集
final class SearchQuerySyntaxTests: XCTestCase {

    private func items() -> [ShelfItem] {
        [
            ShelfItem(url: URL(fileURLWithPath: "/tmp/风景照片.jpg")),
            ShelfItem(url: URL(fileURLWithPath: "/tmp/main.swift")),
            ShelfItem(url: URL(fileURLWithPath: "/tmp/Swift方案.pdf")),
            ShelfItem(url: URL(fileURLWithPath: "/tmp/项目")),
        ]
    }

    /// kind: 中英文别名解析
    func testKindKeywordAliases() {
        XCTAssertEqual(InteractionModel.variant(forKindKeyword: "图片"), .image)
        XCTAssertEqual(InteractionModel.variant(forKindKeyword: "IMAGE"), .image)
        XCTAssertEqual(InteractionModel.variant(forKindKeyword: "photo"), .image)
        XCTAssertEqual(InteractionModel.variant(forKindKeyword: "视频"), .video)
        XCTAssertEqual(InteractionModel.variant(forKindKeyword: "code"), .code)
        XCTAssertEqual(InteractionModel.variant(forKindKeyword: "pdf"), .pdf)
        XCTAssertEqual(InteractionModel.variant(forKindKeyword: "zip"), .archive)
        XCTAssertNil(InteractionModel.variant(forKindKeyword: "不认识的词"))
    }

    /// 解析：kind: token 进类型过滤，其余保留为关键字
    func testParseQuerySplitsKindTokens() {
        let parsed = InteractionModel.parseQuery("kind:图片 风景")
        XCTAssertEqual(parsed.keywords, ["风景"])
        XCTAssertEqual(parsed.variants, [.image])

        let typeAlias = InteractionModel.parseQuery("type:code xx")
        XCTAssertEqual(typeAlias.variants, [.code])

        let plain = InteractionModel.parseQuery("只是关键字")
        XCTAssertEqual(plain.keywords, ["只是关键字"])
        XCTAssertTrue(plain.variants.isEmpty)

        // 无法识别的 kind 值当普通关键字处理
        let fallback = InteractionModel.parseQuery("kind:魔法 swift")
        XCTAssertEqual(fallback.keywords, ["kind:魔法", "swift"])
        XCTAssertTrue(fallback.variants.isEmpty)
    }

    /// 过滤：类型 + 名称交集
    func testFilterByKindAndKeywords() {
        let all = items()
        XCTAssertEqual(
            InteractionModel.filter(all, query: "kind:图片").map(\.name),
            ["风景照片.jpg"]
        )
        XCTAssertEqual(
            InteractionModel.filter(all, query: "kind:swift方案").count, 0,
            "无法识别的 kind 值不当作类型过滤"
        )
        XCTAssertEqual(
            InteractionModel.filter(all, query: "swift kind:code").map(\.name),
            ["main.swift"], "类型与名称关键字取交集"
        )
        XCTAssertEqual(
            InteractionModel.filter(all, query: "kind:pdf kind:code").map(\.name).sorted(),
            ["Swift方案.pdf", "main.swift"], "多个 kind 取并集"
        )
        // 文件夹由磁盘 stat 识别——临时目录构造
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("搜索语法文件夹-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let folderItem = ShelfItem(url: dir)
        XCTAssertEqual(
            InteractionModel.filter([folderItem], query: "kind:文件夹").map(\.name),
            [dir.lastPathComponent]
        )
    }

    /// 多关键字全部命中才保留
    func testMultipleKeywordsRequireAll() {
        let all = items()
        XCTAssertEqual(InteractionModel.filter(all, query: "swift pdf").map(\.name), ["Swift方案.pdf"])
        XCTAssertEqual(InteractionModel.filter(all, query: "swift 不存在").count, 0)
    }

    /// 拖入反馈判定：搜索激活且新条目全部被过滤才提示；空词 / 空集合 / 部分可见不提示
    func testDropHiddenBySearch() {
        let all = items()
        XCTAssertTrue(InteractionModel.dropHiddenBySearch(all, query: "报价单"), "全部不匹配：列表纹丝不动，应提示")
        XCTAssertFalse(InteractionModel.dropHiddenBySearch(all, query: "swift"), "部分可见（main.swift）已有视觉反馈，不提示")
        XCTAssertFalse(InteractionModel.dropHiddenBySearch(all, query: ""), "无搜索词：列表直接可见新条目，不提示")
        XCTAssertFalse(InteractionModel.dropHiddenBySearch(all, query: "   "), "空白搜索词视同无搜索")
        XCTAssertFalse(InteractionModel.dropHiddenBySearch([], query: "报价单"), "空集合（全被去重跳过等）不提示")
    }
}
