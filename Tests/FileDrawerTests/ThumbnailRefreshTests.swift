import XCTest
import AppKit
@testable import FileDrawer

/// 路径改写（重命名 / 移动）后缩略图自动补齐
final class ThumbnailRefreshTests: XCTestCase {

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 4,
        _ condition: @MainActor () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// 生成一张真实 PNG
    private func makePNGFile(in dir: URL, name: String) throws -> URL {
        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSRect(x: 0, y: 0, width: 24, height: 24).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let url = dir.appendingPathComponent(name)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    /// updatePath（重命名 / 移动的底层路径改写）会主动补齐新路径的缩略图
    func testUpdatePathReRequestsThumbnail() throws {
        try MainActor.assumeIsolated {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let oldURL = try makePNGFile(in: dir, name: "旧图.png")
            let item = ShelfItem(url: oldURL)

            let store = ShelfStore.shared
            let original = store.items
            store.items = [item]
            defer { store.items = original }

            let id = item.id
            store.ensureThumb(for: item)
            waitUntil { store.thumbs[id] != nil }
            XCTAssertNotNil(store.thumbs[id], "初始解码应产出缩略图")

            // 重命名到新路径 → updatePath 清空缩略图后应自动补齐
            let newURL = dir.appendingPathComponent("新图.png")
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            store.updatePath(id: id, to: newURL)
            XCTAssertNil(store.thumbs[id], "路径改写后旧缩略图立即失效")

            waitUntil { store.thumbs[id] != nil }
            XCTAssertNotNil(store.thumbs[id], "updatePath 应主动重新解码新路径的缩略图")
        }
    }
}
