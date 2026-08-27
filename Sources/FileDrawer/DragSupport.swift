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
    /// 「大小 · 加入时间」样式的元信息行；两部分各受设置控制，全关时为空串
    @MainActor
    var metaLine: String {
        metaLine(settings: AppSettings.shared)
    }

    @MainActor
    func metaLine(settings: AppSettings) -> String {
        var parts: [String] = []
        if settings.showFileSize { parts.append(ShelfStore.sizeText(for: path)) }
        if settings.showAddedTime { parts.append(Self.relativeAdded(addedAt)) }
        return parts.joined(separator: " · ")
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

// MARK: - 拖出会话结束观察

/// SwiftUI 的 onDrag 只知道拖拽开始，不知道何时落下/取消。
/// 系统拖拽会话开始与结束时都会改写 drag 粘贴板的 changeCount——
/// 两阶段轮询即可探测会话结束（供「拖出后自动收起」使用）。
enum DragSessionObserver {
    /// 在拖拽会话真正结束（落下或取消）后回主线程执行 action。
    /// 需在 onDrag 闭包（即会话开始）时调用。
    static func notifyDragEnd(_ action: @escaping @MainActor () -> Void) {
        Task.detached(priority: .utility) {
            let pasteboard = NSPasteboard(name: .drag)
            func sleep() async {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }

            // 阶段 1：等待会话真正启动（changeCount 增长），最长 2 秒
            let base = pasteboard.changeCount
            var deadline = Date().addingTimeInterval(2)
            while Date() < deadline, pasteboard.changeCount == base {
                await sleep()
            }
            guard pasteboard.changeCount != base else { return }

            // 阶段 2：等待会话结束（再次变化），最长 5 分钟防悬挂
            let started = pasteboard.changeCount
            deadline = Date().addingTimeInterval(300)
            while Date() < deadline, pasteboard.changeCount == started {
                await sleep()
            }

            await MainActor.run { action() }
        }
    }
}
