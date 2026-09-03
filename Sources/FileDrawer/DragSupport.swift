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

// MARK: - 拖入：从外部拖拽载荷中取出文件 URL；文本 / 链接物化成收件箱文件

enum DropFileLoader {
    /// 可接收的载荷类型：文件 URL、链接、纯文本，以及图像 / 视频 / 音频 / PDF 媒体载荷
    /// （浏览器拖图给图像数据、照片 / 邮件附件给文件承诺，解析与物化在 InboxStore）
    static let typeIdentifiers: [String] =
        [
            UTType.fileURL.identifier,
            UTType.url.identifier,
            UTType.utf8PlainText.identifier,
            UTType.plainText.identifier,
        ] + InboxStore.receivableFileTypeIdentifiers

    /// 异步解析一批拖拽提供者中的所有文件 URL。
    /// 各 provider 的完成回调可能乱序到达，落位到序号槽位后再输出，保持拖入时的顺序。
    /// （单个 provider 的解析内部有同步等待，放到并发队列上做，不卡主线程。）
    static func loadAll(
        from providers: [NSItemProvider],
        directory: URL = InboxStore.directory,
        completion: @escaping ([URL]) -> Void
    ) {
        guard !providers.isEmpty else {
            completion([])
            return
        }
        let group = DispatchGroup()
        var results = [URL?](repeating: nil, count: providers.count)
        let lock = NSLock()

        for (index, provider) in providers.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let url = InboxStore.url(fromProvider: provider, directory: directory)
                lock.lock()
                results[index] = url
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(results.compactMap { $0 })
        }
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
        // 大小走 Store 缓存：文件夹要列目录，不能每帧渲染都做
        if settings.showFileSize { parts.append(ShelfStore.shared.cachedSizeText(for: path)) }
        if settings.showAddedTime { parts.append(Self.relativeAdded(addedAt)) }
        return parts.joined(separator: " · ")
    }

    private static let zhFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let enFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func relativeAdded(_ date: Date) -> String {
        let formatter = L10n.isEnglish ? enFormatter : zhFormatter
        return formatter.localizedString(for: date, relativeTo: Date())
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
