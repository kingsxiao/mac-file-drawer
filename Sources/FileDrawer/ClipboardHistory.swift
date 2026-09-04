import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - 剪贴板历史：把系统剪贴板的每次变化留档，一键收进抽屉
//
// 调研背景：Yoink/Dropover 评论区里「剪贴板历史管理」是出现频率最高的可行需求
// （Yoink 用户盛赞其剪贴板历史，Dropover 用户明确留言希望「一键把复制到剪贴板的
// 文字和图片导入抽屉」）。本模块提供后台监控 + 历史面板的数据层：
//
// - 轮询 NSPasteboard.general.changeCount（0.5s，仅启用时），按「文件 > 图像 >
//   链接 > 文本」的优先级与 ⌘V 粘贴同一条判别链（ClipboardSupport）捕获；
// - 隐私：按来源应用排除（默认排除常见密码管理器），条目右键可「排除此应用」，
//   自己写回剪贴板的内容不会再次入档；
// - 持久化：UserDefaults JSON，容量上限淘汰最旧（置顶豁免，与抽屉条目同语义）。

/// 剪贴板条目载荷：捕获时已经归一化，展示与「收进抽屉」都只看这一个类型
enum ClipboardPayload: Equatable, Codable {
    /// 磁盘文件路径（访达拷贝；只记路径，展示时回查存在性）
    case files([String])
    /// 图像数据快照（浏览器 / 预览的「拷贝图像」，TIFF / PNG）
    case image(Data, ext: String)
    /// http(s) 链接
    case link(String)
    /// 纯文本（富文本已展平）

    case text(String)
}

struct ClipboardEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var capturedAt: Date
    /// 置顶：浮在最前，且豁免容量淘汰（与抽屉条目同一语义）
    var pinned: Bool
    /// 复制来源应用（bundle id + 显示名，捕获时的前台应用）
    var sourceBundleID: String?
    var sourceAppName: String?
    var payload: ClipboardPayload

    init(
        payload: ClipboardPayload,
        capturedAt: Date = Date(),
        pinned: Bool = false,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil
    ) {
        self.id = UUID()
        self.capturedAt = capturedAt
        self.pinned = pinned
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.payload = payload
    }
}

// MARK: - 捕获判别（纯函数，可单测）

enum ClipboardCapture {
    /// 文本载荷的存储上限：再长的文本也只留前 64 KB（UserDefaults 不养大对象）
    static let textLimit = 64 * 1024
    /// 图像载荷的存储上限：跳过超大图（截图巨型 TIFF 等），避免历史膨胀
    static let imageLimit = 8 * 1024 * 1024

    /// 默认排除的来源应用（密码管理器：剪贴板历史最经典的隐私投诉来源）
    static let defaultExcludedBundleIDs: Set<String> = [
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
    ]

    /// 从粘贴板归一化出载荷：文件 > 图像 > 链接 > 文本（与 ⌘V 的 pasteableURLs 同优先级）
    /// 返回 nil = 粘贴板为空 / 只有不可识别的内容 / 图像超限。
    /// 文件条目只保留磁盘上仍存在的路径。
    static func payload(from pasteboard: NSPasteboard) -> ClipboardPayload? {
        let files = ClipboardSupport.fileURLs(from: pasteboard)
        if !files.isEmpty {
            let paths = files
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .map(\.path)
            if !paths.isEmpty { return .files(paths) }
        }

        if let image = ClipboardSupport.imagePayload(from: pasteboard) {
            guard image.data.count <= imageLimit else { return nil }
            return .image(image.data, ext: image.ext)
        }

        guard let text = ClipboardSupport.text(from: pasteboard) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let capped = String(trimmed.prefix(textLimit))
        if let link = URL(string: capped),
           ["http", "https"].contains(link.scheme?.lowercased() ?? "") {
            return .link(capped)
        }
        return .text(capped)
    }

    /// 载荷的查重签名：与最新一条相同 = 连续重复复制，不再入档
    static func signature(of payload: ClipboardPayload) -> String {
        switch payload {
        case .files(let paths):
            return "f:" + paths.joined(separator: "\n")
        case .image(let data, _):
            return "i:\(data.count):\(data.prefix(64).hashValue)"
        case .link(let url):
            return "l:\(url)"
        case .text(let text):
            return "t:\(text)"
        }
    }

    /// 条目的主标题（列表首行）
    static func title(of payload: ClipboardPayload) -> String {
        switch payload {
        case .files(let paths):
            guard let first = paths.first else { return L10n.t("文件") }
            let name = (first as NSString).lastPathComponent
            return paths.count > 1
                ? L10n.tf("%@ 等 %d 个文件", name, paths.count)
                : name
        case .image:
            return L10n.t("图像")
        case .link(let url):
            if let link = URL(string: url), let host = link.host {
                return host.replacingOccurrences(of: "www.", with: "")
            }
            return url
        case .text(let text):
            let firstLine = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first
                .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            return firstLine.isEmpty ? L10n.t("文本") : String(firstLine.prefix(120))
        }
    }
}

// MARK: - 历史存储

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    static let shared = ClipboardHistoryStore()

    private static let storageKey = "com.wangxiao.filedrawer.clipboardHistory.v1"
    /// 测试注入的独立 defaults（nil = UserDefaults.standard）
    private let defaults: UserDefaults
    /// 排除列表 / 容量上限的来源（应用代码 = shared；测试注入独立套件）
    private let settings: AppSettings
    /// 轮询间隔：0.5s 是剪贴板管理器的惯用档（再快收益递减，再慢会漏快节奏复制）
    private static let tickInterval: TimeInterval = 0.5

    /// 历史（最新在前）；置顶条目在展示层浮到最前，存储顺序仍是捕获顺序
    @Published private(set) var entries: [ClipboardEntry] = [] {
        didSet { persist() }
    }

    private var timer: Timer?
    /// 监控的粘贴板（默认系统剪贴板；测试注入独立实例避免污染真实剪贴板）
    private let pasteboard: NSPasteboard
    /// 上一轮看到的 changeCount：不变则跳过整轮解析
    private var lastChangeCount: Int
    /// 本应用自己写回剪贴板产生的 changeCount 集合（copyBack 不回声入档）
    private var selfWrittenChangeCounts: Set<Int> = []

    /// 初始化后立即生效的监控开关（设置变化时由 AppSettings 订阅驱动）
    private(set) var isMonitoring = false

    /// 测试可注入独立 defaults / settings / pasteboard（nil = 应用默认值）
    init(
        defaults: UserDefaults? = nil,
        settings: AppSettings? = nil,
        pasteboard: NSPasteboard? = nil
    ) {
        self.defaults = defaults ?? .standard
        self.settings = settings ?? AppSettings.shared
        self.pasteboard = pasteboard ?? .general
        self.lastChangeCount = self.pasteboard.changeCount
        if let data = self.defaults.data(forKey: Self.storageKey) {
            // 解码失败（跨版本结构变化）按空历史处理，宁丢历史不崩
            if let saved = try? JSONDecoder().decode([ClipboardEntry].self, from: data) {
                entries = saved
            }
        }
    }

    // MARK: 监控

    /// 开始 / 停止监控（幂等）。设置开关与生命周期事件调用。
    func setMonitoring(_ active: Bool) {
        guard active != isMonitoring else { return }
        isMonitoring = active
        if active {
            lastChangeCount = pasteboard.changeCount
            let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.tick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// 单轮轮询：changeCount 未变跳过；自己写回的跳过；然后捕获入档
    func tick() {
        guard isMonitoring else { return }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard !selfWrittenChangeCounts.contains(count) else {
            selfWrittenChangeCounts.remove(count)
            return
        }
        let source = NSWorkspace.shared.frontmostApplication
        capture(
            from: pasteboard,
            sourceBundleID: source?.bundleIdentifier,
            sourceAppName: source?.localizedName
        )
    }

    /// 捕获一条（过滤与查重后入档）。独立出来供测试直接驱动。
    /// 返回是否真的入档。
    @discardableResult
    func capture(
        from pasteboard: NSPasteboard,
        sourceBundleID: String?,
        sourceAppName: String?
    ) -> Bool {
        guard let payload = ClipboardCapture.payload(from: pasteboard) else { return false }
        return insert(
            payload: payload,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName
        )
    }

    /// 入档入口：来源排除、连续重复查重、容量淘汰都在这里（可单测）
    @discardableResult
    func insert(
        payload: ClipboardPayload,
        sourceBundleID: String?,
        sourceAppName: String?
    ) -> Bool {
        // 隐私：被排除的来源应用（设置里可增删；默认含密码管理器）
        if let bundleID = sourceBundleID {
            guard !settings.clipboardExcludedApps.contains(bundleID) else { return false }
        }
        // 连续重复复制：与最新一条相同则跳过（复制 N 次只记一次）
        let signature = ClipboardCapture.signature(of: payload)
        if let newest = entries.first,
           ClipboardCapture.signature(of: newest.payload) == signature {
            return false
        }
        let entry = ClipboardEntry(
            payload: payload,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName
        )
        entries.insert(entry, at: 0)
        enforceLimit()
        return true
    }

    /// 容量上限：淘汰最旧的非置顶条目（置顶豁免）
    private func enforceLimit() {
        let limit = settings.clipboardHistoryLimit.count
        let unpinned = entries.filter { !$0.pinned }
        let overflow = unpinned.count - limit
        guard overflow > 0 else { return }
        // 最旧的在尾部：从后往前剔除 overflow 个非置顶条目
        var dropIDs = Set<UUID>()
        var remaining = overflow
        for entry in entries.reversed() where !entry.pinned {
            dropIDs.insert(entry.id)
            remaining -= 1
            if remaining == 0 { break }
        }
        entries.removeAll { dropIDs.contains($0.id) }
    }

    // MARK: 编辑

    func removeEntry(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    func togglePin(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].pinned.toggle()
    }

    func clear() {
        entries.removeAll()
    }

    /// 置顶在前、其余按捕获顺序（最新在前）的展示序列
    func displayedEntries(matching query: String) -> [ClipboardEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty
            ? entries
            : entries.filter { entry in
                let haystack = [ClipboardCapture.title(of: entry.payload), entry.sourceAppName ?? ""]
                    .joined(separator: "\n")
                // 文本 / 链接载荷还匹配正文本身
                switch entry.payload {
                case .text(let text): return haystack.localizedStandardContains(trimmed)
                        || text.localizedStandardContains(trimmed)
                case .link(let url): return haystack.localizedStandardContains(trimmed)
                        || url.localizedStandardContains(trimmed)
                default: return haystack.localizedStandardContains(trimmed)
                }
            }
        let pinned = base.filter(\.pinned)
        let rest = base.filter { !$0.pinned }
        return pinned + rest
    }

    // MARK: 拷回剪贴板

    /// 把条目内容写回监控的粘贴板；写回的 changeCount 记为自发，下一轮不重复入档
    func copyBack(_ entry: ClipboardEntry) {
        pasteboard.clearContents()
        switch entry.payload {
        case .files(let paths):
            let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
            pasteboard.writeObjects(urls)
        case .image(let data, let ext):
            let type: NSPasteboard.PasteboardType = ext == "png" ? .png : .tiff
            pasteboard.setData(data, forType: type)
        case .link(let url):
            pasteboard.setString(url, forType: .string)
        case .text(let text):
            pasteboard.setString(text, forType: .string)
        }
        selfWrittenChangeCounts.insert(pasteboard.changeCount)
    }

    // MARK: 收进抽屉

    /// 把条目收进抽屉（当前分组）：文件原样入列；文本 / 链接 / 图像物化成收件箱文件。
    /// 返回 (新增, 重复跳过, 失效跳过)。
    @discardableResult
    func adopt(
        _ entry: ClipboardEntry,
        into store: ShelfStore,
        directory: URL = InboxStore.directory
    ) -> (added: Int, skippedDuplicates: Int, invalid: Int) {
        let urls: [URL]
        switch entry.payload {
        case .files(let paths):
            let valid = paths.filter { FileManager.default.fileExists(atPath: $0) }
            let invalid = paths.count - valid.count
            let result = store.add(urls: valid.map { URL(fileURLWithPath: $0) })
            return (result.added, result.skippedDuplicates, invalid)

        case .image(let data, let ext):
            urls = InboxStore.materialize(imageData: data, ext: ext, directory: directory)
                .map { [$0] } ?? []
        case .link(let url):
            urls = URL(string: url)
                .flatMap { InboxStore.materialize(url: $0, directory: directory) }
                .map { [$0] } ?? []
        case .text(let text):
            urls = InboxStore.materialize(text: text, directory: directory).map { [$0] } ?? []
        }
        guard !urls.isEmpty else { return (0, 0, 1) }
        let result = store.add(urls: urls)
        return (result.added, result.skippedDuplicates, 0)
    }

    // MARK: 持久化

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
