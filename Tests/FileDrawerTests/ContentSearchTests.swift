import XCTest
@testable import FileDrawer

/// Spotlight 内容搜索：转义、起搜门槛、名称未命中时按内容命中回退
final class ContentSearchTests: XCTestCase {

    /// 查询串转义：引号 / 反斜杠 / 星号不进入谓词
    func testEscapeStripsPredicateCharacters() {
        XCTAssertEqual(SpotlightContentSearch.escaped("正常词"), "正常词")
        XCTAssertEqual(SpotlightContentSearch.escaped("a\"b\\c*d"), "a b c d")
    }

    /// 起搜门槛：设置关 / 少于 2 字符不起查询
    func testShouldSearchGates() {
        XCTAssertFalse(SpotlightContentSearch.shouldSearch("任何词", enabled: false), "设置关闭不起查询")
        XCTAssertFalse(SpotlightContentSearch.shouldSearch("a", enabled: true))
        XCTAssertFalse(SpotlightContentSearch.shouldSearch("  ", enabled: true))
        XCTAssertTrue(SpotlightContentSearch.shouldSearch("ab", enabled: true))
        XCTAssertTrue(SpotlightContentSearch.shouldSearch(" 关键词 ", enabled: true))
    }

    /// 名称未命中但内容命中 → 保留在结果里；内容命中仍受 kind: 类型过滤约束
    func testFilterFallsBackToContentMatches() {
        let items = [
            ShelfItem(url: URL(fileURLWithPath: "/tmp/报告.pdf")),
            ShelfItem(url: URL(fileURLWithPath: "/tmp/照片.jpg")),
            ShelfItem(url: URL(fileURLWithPath: "/tmp/别的.txt")),
        ]
        let contentHit = items[0].id // 「报告.pdf」内容里包含关键词
        let filtered = InteractionModel.filter(items, query: "预算", contentMatched: [contentHit])
        XCTAssertEqual(filtered.map(\.name), ["报告.pdf"], "内容命中回退保留")

        // 类型过滤优先于内容回退：kind:image 时即使内容命中也不出现
        let typed = InteractionModel.filter(items, query: "kind:图片 预算", contentMatched: [contentHit])
        XCTAssertTrue(typed.isEmpty)

        // 无关键字（纯 kind:）不触发内容回退
        let kindOnly = InteractionModel.filter(items, query: "kind:pdf", contentMatched: [contentHit])
        XCTAssertEqual(kindOnly.map(\.name), ["报告.pdf"], "kind 过滤独立于内容命中")
    }
}
