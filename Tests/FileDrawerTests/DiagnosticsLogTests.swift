import XCTest
@testable import FileDrawer

/// 诊断日志：环形截断、报告组装、埋点生效
final class DiagnosticsLogTests: XCTestCase {

    override func tearDownWithError() throws {
        MainActor.assumeIsolated { DiagnosticsLog.shared.reset() }
    }

    /// 环形缓冲：超出容量丢最旧
    func testRingBufferEvictsOldest() {
        MainActor.assumeIsolated {
            let log = DiagnosticsLog.shared
            log.reset()
            for idx in 0..<(DiagnosticsLog.capacity + 20) {
                log.log("test", "条目\(idx)")
            }
            XCTAssertEqual(log.entries.count, DiagnosticsLog.capacity)
            XCTAssertEqual(log.entries.first?.message, "条目20", "最旧的 20 条被丢弃")
            XCTAssertEqual(log.entries.last?.message, "条目\(DiagnosticsLog.capacity + 19)")
        }
    }

    /// 报告组装：环境摘要 + 每条一行（含时间/分类/消息）
    func testReportComposition() {
        let entries = [
            DiagnosticsLog.Entry(date: Date(timeIntervalSince1970: 1_700_000_000), category: "auto", message: "add added=1"),
            DiagnosticsLog.Entry(date: Date(timeIntervalSince1970: 1_700_000_001), category: "url", message: "toggle"),
        ]
        let report = DiagnosticsLog.report(
            version: "1.6.0",
            build: "6",
            systemVersion: "25.6.0",
            itemCount: 12,
            drawerCount: 3,
            entries: entries
        )
        XCTAssertTrue(report.contains("版本: 1.6.0 (6)"))
        XCTAssertTrue(report.contains("条目: 12 个 / 3 组"))
        XCTAssertTrue(report.contains("[auto] add added=1"))
        XCTAssertTrue(report.contains("[url] toggle"))
        XCTAssertTrue(report.contains("日志条目: 2"))
    }

    /// 共享命令层埋点生效（URL 与 Intent 同路径）
    func testAutomationActionsAreLogged() {
        MainActor.assumeIsolated {
            let log = DiagnosticsLog.shared
            log.reset()
            _ = DrawerCommands.removeItems(group: "不存在的分组-\(UUID())", limit: 5)
            // 未知分组在 drawerID 解析处返回 0，不产生 remove 日志——用空当前分组同样无日志；
            // 改用 pin（空分组无条目也无日志）。因此验证「有作用对象时必产生日志」：
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("诊断样本.txt")
            try? Data("x".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: dir) }

            let store = ShelfStore.shared
            let original = store.items
            store.items = []
            defer { store.items = original }

            _ = DrawerCommands.add(paths: [file.path], group: nil)
            XCTAssertTrue(
                log.entries.contains { $0.category == "auto" && $0.message.contains("add") },
                "放入动作应有诊断日志"
            )
        }
    }
}
