import AppKit
import UniformTypeIdentifiers

// MARK: - 拖出：把抽屉里的条目变成真正的"文件拖拽"

extension ShelfItem {
    /// 生成可拖出的 NSItemProvider：
    /// 1) 文件表示——目标端（Finder 等）以"拷贝真实文件"的方式接收；
    /// 2) file-url 数据表示——让普通目标端立即拿到文件地址。
    func dragProvider() -> NSItemProvider {
        let url = self.url
        let provider = NSItemProvider()
        provider.suggestedName = url.lastPathComponent

        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.data.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(url, false, nil)
            return nil
        }

        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            completion((url as NSURL).dataRepresentation, nil)
            return nil
        }

        return provider
    }
}

// MARK: - 拖入：从外部拖拽载荷中取出文件 URL

enum DropFileLoader {
    static let typeIdentifiers = [UTType.fileURL.identifier]

    /// 异步解析一批拖拽提供者中的所有文件 URL。
    static func loadAll(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        guard !providers.isEmpty else {
            completion([])
            return
        }
        let group = DispatchGroup()
        var collected = [URL]()
        let lock = NSLock()

        for provider in providers {
            group.enter()
            loadOne(provider) { url in
                if let url {
                    lock.lock()
                    collected.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(collected)
        }
    }

    private static func loadOne(_ provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        // 统一走 NSSecureCoding 的 URL 解码（访达与绝大多数应用的标准拖拽形式）
        guard provider.canLoadObject(ofClass: URL.self) else {
            complete(nil, completion)
            return
        }
        provider.loadObject(ofClass: URL.self) { obj, _ in
            complete(obj, completion)
        }
    }

    private static func complete(_ url: URL?, _ completion: @escaping (URL?) -> Void) {
        DispatchQueue.main.async { completion(url) }
    }
}

// MARK: - 展示辅助

extension ShelfItem {
    /// 「大小 · 加入时间」样式的元信息行
    var metaLine: String {
        [ShelfStore.sizeText(for: path), Self.relativeAdded(addedAt)].joined(separator: " · ")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func relativeAdded(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
