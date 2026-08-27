import XCTest
import AppKit
@testable import FileDrawer

/// 缩略图磁盘缓存：指纹键、读写往返、容量淘汰
final class ThumbnailDiskCacheTests: XCTestCase {

    private var cacheDir: URL!

    override func setUpWithError() throws {
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cacheDir)
    }

    /// 同指纹同键；路径 / 修改时间 / 大小任一变化键即变化
    func testMakeKeyIsDeterministicAndSensitive() {
        let base = ThumbnailDiskCache.makeKey(path: "/tmp/a.jpg", modifiedAt: 100, fileSize: 2048)
        XCTAssertEqual(base, ThumbnailDiskCache.makeKey(path: "/tmp/a.jpg", modifiedAt: 100, fileSize: 2048))
        XCTAssertNotEqual(base, ThumbnailDiskCache.makeKey(path: "/tmp/b.jpg", modifiedAt: 100, fileSize: 2048), "路径变化 → 键变化")
        XCTAssertNotEqual(base, ThumbnailDiskCache.makeKey(path: "/tmp/a.jpg", modifiedAt: 101, fileSize: 2048), "修改时间变化 → 键变化")
        XCTAssertNotEqual(base, ThumbnailDiskCache.makeKey(path: "/tmp/a.jpg", modifiedAt: 100, fileSize: 4096), "大小变化 → 键变化")
        XCTAssertEqual(base.count, 64, "SHA-256 十六进制 64 字符")
    }

    /// 真实文件指纹：可读且文件内容变化后指纹变化；缺失文件返回 nil
    func testFingerprintTracksFileChanges() throws {
        let file = cacheDir.appendingPathComponent("样本.txt")
        try Data(repeating: 0, count: 128).write(to: file)

        let first = ThumbnailDiskCache.fingerprint(of: file)
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.fileSize, 128)

        // 内容变化（大小不同）→ 指纹随之变化，缓存键自然失效
        try Data(repeating: 0, count: 512).write(to: file)
        let second = ThumbnailDiskCache.fingerprint(of: file)
        XCTAssertEqual(second?.fileSize, 512)
        XCTAssertNotEqual(
            ThumbnailDiskCache.makeKey(path: file.path, modifiedAt: first!.modifiedAt, fileSize: first!.fileSize),
            ThumbnailDiskCache.makeKey(path: file.path, modifiedAt: second!.modifiedAt, fileSize: second!.fileSize),
            "内容变化后缓存键应不同"
        )

        XCTAssertNil(ThumbnailDiskCache.fingerprint(of: cacheDir.appendingPathComponent("不存在.txt")))
    }

    /// 读写往返：像素尺寸保留
    func testStoreAndImageRoundTrip() throws {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        DrawerThemeTestHelper.fillAccentColor(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        image.unlockFocus()

        let key = "roundtrip-key"
        ThumbnailDiskCache.store(image, forKey: key, directory: cacheDir)
        let loaded = ThumbnailDiskCache.image(forKey: key, directory: cacheDir)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.size.width ?? 0, 16, accuracy: 1)
        XCTAssertEqual(loaded?.size.height ?? 0, 16, accuracy: 1)

        XCTAssertNil(ThumbnailDiskCache.image(forKey: "不存在的键", directory: cacheDir))
    }

    /// 容量淘汰：超出上限时最旧的缓存被移除
    func testEnforceLimitEvictsOldest() throws {
        let fm = FileManager.default
        let now = Date()
        for idx in 0..<5 {
            let url = cacheDir.appendingPathComponent("thumb-\(idx).png")
            try Data("x".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(Double(idx))], ofItemAtPath: url.path)
        }
        ThumbnailDiskCache.enforceLimit(maxEntries: 3, directory: cacheDir)
        let remaining = try fm.contentsOfDirectory(atPath: cacheDir.path).sorted()
        XCTAssertEqual(remaining, ["thumb-2.png", "thumb-3.png", "thumb-4.png"], "最旧的两个被淘汰")
    }
}

/// 测试辅助：画一块品牌色
enum DrawerThemeTestHelper {
    static func fillAccentColor(in rect: NSRect) {
        NSColor(red: 0.42, green: 0.36, blue: 0.9, alpha: 1).setFill()
        rect.fill()
    }
}
