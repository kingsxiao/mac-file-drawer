import AppKit
import SwiftUI
import Combine
import ImageIO
import AVFoundation
import PDFKit

// MARK: - 数据模型

struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    var path: String
    var addedAt: Date

    init(url: URL) {
        self.id = UUID()
        self.path = url.standardizedFileURL.path
        self.addedAt = Date()
    }

    /// 测试与工具场景：可注入确定的时间
    init(url: URL, addedAt: Date) {
        self.id = UUID()
        self.path = url.standardizedFileURL.path
        self.addedAt = addedAt
    }

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }

    var kind: FileKind { FileKind(url: url) }
}

// MARK: - Store

@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()
    private static let defaultsKey = "com.wangxiao.filedrawer.items"

    @Published var items: [ShelfItem] = [] {
        didSet { persist() }
    }

    /// 缩略图缓存（图片/视频真实预览）
    @Published var thumbs: [UUID: NSImage] = [:]
    private var thumbFailed = Set<UUID>()
    /// 设置里重新打开缩略图时，为已经显示过（错过 onAppear）的行补齐
    private var thumbnailSettingCancellable: AnyCancellable?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([ShelfItem].self, from: data) {
            var restored = saved
            let settings = AppSettings.shared
            // 默认只保留仍然存在的文件；可在设置里关闭（保留失效条目，等手动移除）
            if settings.removeMissingOnLaunch {
                restored = restored.filter { FileManager.default.fileExists(atPath: $0.path) }
            }
            restored = Self.pruned(restored, policy: settings.autoClean)
            restored = Self.trimmed(restored, limit: settings.maxItems)
            items = restored
        }
        // dropFirst：跳过订阅时的当前值，只在「从关到开」时补齐
        thumbnailSettingCancellable = AppSettings.shared.$showThumbnails
            .dropFirst()
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { _ in
                MainActor.assumeIsolated {
                    ShelfStore.shared.ensureThumbsForAll()
                }
            }
    }

    func add(urls: [URL]) {
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !items.contains(where: { $0.path == path }) else { continue }
            items.append(ShelfItem(url: url))
        }
        enforceCapacityLimit()
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        thumbs[item.id] = nil
        thumbFailed.remove(item.id)
    }

    /// 手动清理：丢弃硬盘上已不存在的条目（设置面板「立即清理」）
    func removeMissing() {
        let missing = items.filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard !missing.isEmpty else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            for item in missing {
                thumbs[item.id] = nil
                thumbFailed.remove(item.id)
            }
            items.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    /// 「移动到文件夹」后把条目改写为指向新路径
    func updatePath(id: UUID, to url: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].path = url.standardizedFileURL.path
        thumbs[id] = nil
        thumbFailed.remove(id)
    }

    // MARK: 维护策略（纯函数，可单测）

    /// 过期自动清理：丢弃加入时间早于策略窗口的条目
    nonisolated static func pruned(_ items: [ShelfItem], policy: AutoCleanPolicy, now: Date = Date()) -> [ShelfItem] {
        guard let days = policy.days else { return items }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return items.filter { $0.addedAt >= cutoff }
    }

    /// 容量上限：超出时淘汰最早加入的条目，保留原有相对顺序
    nonisolated static func trimmed(_ items: [ShelfItem], limit: MaxItemsPolicy) -> [ShelfItem] {
        guard let max = limit.count, items.count > max else { return items }
        let keep = Set(
            items
                .sorted { $0.addedAt > $1.addedAt }
                .prefix(max)
                .map(\.id)
        )
        return items.filter { keep.contains($0.id) }
    }

    @MainActor
    private func enforceCapacityLimit() {
        let capped = Self.trimmed(items, limit: AppSettings.shared.maxItems)
        if capped.count != items.count {
            let removed = Set(items.map(\.id)).subtracting(Set(capped.map(\.id)))
            for id in removed {
                thumbs[id] = nil
                thumbFailed.remove(id)
            }
            items = capped
        }
    }

    func clear() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            items.removeAll()
        }
        thumbs.removeAll()
        thumbFailed.removeAll()
    }

    // MARK: 缩略图

    /// 行首次出现时调用；解码在后台线程进行，完成后自动刷新行。
    /// 条目在解码完成前被移除时，结果会被丢弃（孤儿回调守卫）。
    func ensureThumb(for item: ShelfItem) {
        guard AppSettings.shared.showThumbnails else { return }
        guard thumbs[item.id] == nil, thumbFailed.contains(item.id) == false else { return }
        guard item.kind.producesThumbnail else { return }
        let variant = item.kind.variant
        let id = item.id
        let url = item.url
        Task.detached(priority: .utility) {
            let image: NSImage?
            switch variant {
            case .image: image = Self.downsampledImage(url)
            case .video: image = Self.videoThumbnail(url)
            case .pdf:   image = Self.pdfThumbnail(url)
            default:     image = nil
            }
            await ShelfStore.shared.setThumb(image, for: id)
        }
    }

    /// 为当前所有条目补齐缩略图（设置重新打开时调用；已有/已失败的会自动跳过）
    func ensureThumbsForAll() {
        guard AppSettings.shared.showThumbnails else { return }
        for item in items { ensureThumb(for: item) }
    }

    @MainActor
    fileprivate func setThumb(_ image: NSImage?, for id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        if let image {
            thumbs[id] = image
        } else {
            thumbFailed.insert(id)
        }
    }

    private nonisolated static func downsampledImage(_ url: URL) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
        ]
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private nonisolated static func videoThumbnail(_ url: URL) -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        var actualTime = CMTime.zero
        if let cg = try? generator.copyCGImage(at: .zero, actualTime: &actualTime) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return nil
    }

    /// PDF 首页缩略图：按页面长边等比缩到 256px
    private nonisolated static func pdfThumbnail(_ url: URL) -> NSImage? {
        guard let document = PDFDocument(url: url),
              document.pageCount > 0,
              let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let ratio = min(1, 256 / max(bounds.width, bounds.height))
        return page.thumbnail(
            of: CGSize(width: bounds.width * ratio, height: bounds.height * ratio),
            for: .mediaBox
        )
    }

    func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    nonisolated static func sizeText(for path: String) -> String {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            let count = (try? FileManager.default.contentsOfDirectory(atPath: path))?.count ?? 0
            return "\(count) 个项目"
        }
        let rawSize = (try? FileManager.default.attributesOfItem(atPath: path))?[.size]
        var value: Int64 = 0
        if let n = rawSize as? NSNumber { value = n.int64Value }
        switch value {
        case ..<1024: return "\(value) B"
        case ..<1_048_576: return String(format: "%.0f KB", Double(value) / 1024)
        case ..<1_073_741_824: return String(format: "%.1f MB", Double(value) / 1_048_576)
        default: return String(format: "%.2f GB", Double(value) / 1_073_741_824)
        }
    }
}
