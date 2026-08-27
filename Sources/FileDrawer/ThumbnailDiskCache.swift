import AppKit
import CryptoKit
import Foundation

// MARK: - 缩略图磁盘缓存
//
// 图片 / 视频 / PDF 的缩略图解码都不便宜（视频要抽帧、PDF 要渲染首页），
// 每次启动重解码一遍纯属浪费。这里按「路径 + 修改时间 + 大小」的指纹
// 把缩略图落到 ~/Library/Caches（系统可回收目录），下次启动直接读缓存。
// 文件被原地替换（mtime/size 变化）时指纹变化，自然失效重新解码。

enum ThumbnailDiskCache {
    /// 缓存目录（~/Library/Caches/FileDrawer/Thumbnails），按需创建
    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("FileDrawer/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 条目数上限：超过时按修改时间淘汰最旧的缓存文件
    static let maxEntries = 300

    // MARK: 指纹与键（纯函数，可单测）

    /// 缓存键：指纹的十六进制摘要。同指纹同名，文件变化指纹即变。
    static func makeKey(path: String, modifiedAt: Double, fileSize: Int) -> String {
        let raw = "\(path)|\(String(format: "%.0f", modifiedAt))|\(fileSize)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 文件指纹：修改时间 + 大小；文件不存在返回 nil。
    /// 注意克隆 URL 再取值——URL 对象会缓存 resource values，
    /// 同一实例第二次读取会拿到旧值（原地替换的文件就永远识别不出来了）。
    static func fingerprint(of url: URL) -> (modifiedAt: Double, fileSize: Int)? {
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        ) else {
            return nil
        }
        guard values.isRegularFile == true else { return nil }
        return (
            modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            fileSize: values.fileSize ?? 0
        )
    }

    // MARK: 读写

    /// 读缓存；不存在或解码失败返回 nil
    static func image(forKey key: String, directory: URL = directory) -> NSImage? {
        let url = directory.appendingPathComponent("\(key).png")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    /// 写缓存（PNG）；失败静默——缓存只是加速器，不保证成功
    static func store(_ image: NSImage, forKey key: String, directory: URL = directory) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = directory.appendingPathComponent("\(key).png")
        try? png.write(to: url, options: .atomic)
    }

    /// 缓存条数超限时淘汰最旧的（按缓存文件修改时间）
    static func enforceLimit(maxEntries: Int = maxEntries, directory: URL = directory) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        guard children.count > maxEntries else { return }
        let dated: [(url: URL, date: Date)] = children.compactMap { child in
            guard let date = try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                return nil
            }
            return (child, date)
        }
        let excess = dated
            .sorted { $0.date < $1.date }
            .prefix(dated.count - maxEntries)
        for entry in excess {
            try? fm.removeItem(at: entry.url)
        }
    }

    /// 清空全部缓存（调试 / 测试用）
    static func removeAll(directory: URL = directory) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for child in children { try? fm.removeItem(at: child) }
    }
}
