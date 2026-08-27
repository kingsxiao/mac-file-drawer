import XCTest
import AppKit
@testable import FileDrawer

/// 轻提示通道 + add 的重复计数 + 富文本粘贴
final class NoticesAndRichPasteTests: XCTestCase {

    /// add 返回新增数与跳过的重复数（含同批次内重复）
    func testAddCountsDuplicates() throws {
        MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let store = ShelfStore.shared
            let original = store.items
            let a = dir.appendingPathComponent("甲.txt")
            let b = dir.appendingPathComponent("乙.txt")
            try? Data("a".utf8).write(to: a)
            try? Data("b".utf8).write(to: b)
            store.items = []
            defer { store.items = original }

            let first = store.add(urls: [a, b])
            XCTAssertEqual(first.added, 2)
            XCTAssertEqual(first.skippedDuplicates, 0)

            // 再来一批：甲重复 + 批内自身重复一份
            let second = store.add(urls: [a, a, b])
            XCTAssertEqual(second.added, 0)
            XCTAssertEqual(second.skippedDuplicates, 3)
            XCTAssertEqual(store.items.count, 2)
        }
    }

    /// 轻提示：立即生效、新提示覆盖旧提示（2.2 秒后自动清空）
    func testPostNoticeOverwrites() {
        MainActor.assumeIsolated {
            let store = ShelfStore.shared
            store.postNotice("第一条")
            XCTAssertEqual(store.notice, "第一条")
            store.postNotice("第二条")
            XCTAssertEqual(store.notice, "第二条", "新提示应立即覆盖旧提示")
        }
    }

    /// 富文本剪贴板（RTF，无 string 表示）也能提取纯文本
    func testRichTextPasteFallsBackToPlain() throws {
        let attributed = NSAttributedString(string: "富文本内容", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
        ])
        let rtf = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.rtf], owner: nil)
        pasteboard.setData(rtf, forType: .rtf)

        let text = ClipboardSupport.text(from: pasteboard)
        XCTAssertEqual(text, "富文本内容")

        // 标准纯文本路径仍然优先
        pasteboard.clearContents()
        pasteboard.setString("普通文本", forType: .string)
        XCTAssertEqual(ClipboardSupport.text(from: pasteboard), "普通文本")
    }
}
