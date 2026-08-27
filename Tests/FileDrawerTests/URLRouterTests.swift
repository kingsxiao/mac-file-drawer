import XCTest
@testable import FileDrawer

/// URL Scheme 自动化接口：filedrawer://add / reveal / toggle / expand / collapse
final class URLRouterTests: XCTestCase {

    private func action(_ raw: String) -> URLRouter.Action? {
        URLRouter.action(for: URL(string: raw)!)
    }

    func testAddSingleAndMultiplePaths() {
        XCTAssertEqual(
            action("filedrawer://add?path=/tmp/报告.pdf"),
            .add(paths: ["/tmp/报告.pdf"], group: nil)
        )
        XCTAssertEqual(
            action("filedrawer://add?path=/tmp/a.pdf&path=/tmp/b.txt"),
            .add(paths: ["/tmp/a.pdf", "/tmp/b.txt"], group: nil)
        )
    }

    /// 中文 / 空格路径的百分号编码往返
    func testAddEncodedPathRoundTrip() {
        XCTAssertEqual(
            action("filedrawer://add?path=%2Ftmp%2F%E6%8A%A5%E5%91%8A%20v2.pdf"),
            .add(paths: ["/tmp/报告 v2.pdf"], group: nil)
        )
    }

    func testRevealToggleExpandCollapse() {
        XCTAssertEqual(action("filedrawer://reveal?path=/tmp/x.txt"), .reveal(path: "/tmp/x.txt"))
        XCTAssertEqual(action("filedrawer://toggle"), .toggle)
        XCTAssertEqual(action("filedrawer://expand"), .expand)
        XCTAssertEqual(action("filedrawer://collapse"), .collapse)
        // host 大小写不敏感
        XCTAssertEqual(action("filedrawer://EXPAND"), .expand)
    }

    func testInvalidURLsReturnNil() {
        XCTAssertNil(action("https://add?path=/tmp/a.txt"), "scheme 不符")
        XCTAssertNil(action("filedrawer://add"), "add 缺 path 参数")
        XCTAssertNil(action("filedrawer://add?path="), "空 path 不算数")
        XCTAssertNil(action("filedrawer://reveal"), "reveal 缺 path 参数")
        XCTAssertNil(action("filedrawer://未知动作"))
    }

    /// group 参数：指定分组（放入时不存在则创建）
    func testGroupParameterParsing() {
        XCTAssertEqual(
            action("filedrawer://add?path=/tmp/a.pdf&group=工作"),
            .add(paths: ["/tmp/a.pdf"], group: "工作")
        )
        // 空白分组视为未指定
        XCTAssertEqual(
            action("filedrawer://add?path=/tmp/a.pdf&group=%20%20"),
            .add(paths: ["/tmp/a.pdf"], group: nil)
        )
        // 不影响 reveal 等其他动作
        XCTAssertEqual(action("filedrawer://reveal?path=/tmp/x.txt"), .reveal(path: "/tmp/x.txt"))
    }
}
