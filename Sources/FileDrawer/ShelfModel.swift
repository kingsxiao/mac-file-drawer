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
    /// 置顶：排序时浮到最前，且免于过期清理与容量淘汰
    var pinned: Bool
    /// 所属分组（多抽屉）；旧数据迁移时统一归入默认分组，正常运行期不为 nil
    var drawerID: UUID?
    /// 类型识别（含一次磁盘 stat）在构造时算好存起来；
    /// 渲染路径每次 body 都会读它，现场重算会让悬停/滚动每帧都打 I/O。
    /// 文件被原地替换成别的类型属罕见场景，不值得为此每帧重识别。
    var kind: FileKind

    init(url: URL) {
        self.init(url: url, addedAt: Date())
    }

    /// 测试与工具场景：可注入确定的时间
    init(url: URL, addedAt: Date = Date(), pinned: Bool = false, drawerID: UUID? = nil) {
        self.id = UUID()
        self.path = url.standardizedFileURL.path
        self.addedAt = addedAt
        self.pinned = pinned
        self.drawerID = drawerID
        self.kind = FileKind(url: url)
    }

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }

    // 持久化格式只含 id/path/addedAt/pinned/drawerID；kind 由 path 反推，避免冗余与失同步
    private enum CodingKeys: String, CodingKey { case id, path, addedAt, pinned, drawerID }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.path = try container.decode(String.self, forKey: .path)
        self.addedAt = try container.decode(Date.self, forKey: .addedAt)
        // 旧版本持久化里没有 pinned / drawerID：默认未置顶、归属默认分组（由 Store 归一化）
        self.pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        self.drawerID = try container.decodeIfPresent(UUID.self, forKey: .drawerID)
        self.kind = FileKind(url: URL(fileURLWithPath: path))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encode(pinned, forKey: .pinned)
        try container.encodeIfPresent(drawerID, forKey: .drawerID)
    }
}

// MARK: - 撤销快照：移除 / 清空后保留一段时间，供「还原」取回

struct RemovalSnapshot: Equatable {
    struct Entry: Equatable {
        let item: ShelfItem
        /// 被移除时在列表中的位置，还原时按原位插回
        let index: Int
    }
    let entries: [Entry]
    /// toast 文案（如 已移除「xx.txt」 / 已清空抽屉（3 个条目））
    let summary: String

    static func == (lhs: RemovalSnapshot, rhs: RemovalSnapshot) -> Bool {
        lhs.entries.map(\.item.id) == rhs.entries.map(\.item.id)
            && lhs.entries.map(\.index) == rhs.entries.map(\.index)
            && lhs.summary == rhs.summary
    }
}

// MARK: - 分组（多抽屉）：条目按组划分，抽屉一次展示一组

struct DrawerGroup: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

// MARK: - Store

@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()
    private static let defaultsKey = "com.wangxiao.filedrawer.items"
    private static let drawersKey = "com.wangxiao.filedrawer.drawers"
    private static let currentDrawerKey = "com.wangxiao.filedrawer.currentDrawer"
    private static let drawerLimitsKey = "com.wangxiao.filedrawer.drawerLimits"
    /// 旧数据迁移 / 全新安装时的默认分组名
    static let defaultDrawerName = "默认"
    /// 分组容量覆盖表里兜底的「无分组」键（异常数据归入同一名额池）
    nonisolated static let unassignedDrawerID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    @Published var items: [ShelfItem] = [] {
        didSet {
            persist()
            refreshMissingStatus()
        }
    }
    /// 全部分组（至少一个；顺序即切换菜单顺序）
    @Published private(set) var drawers: [DrawerGroup] = [] {
        didSet { persistDrawers() }
    }
    /// 当前展示的分组（init 里立即替换为真实值）
    @Published private(set) var currentDrawerID: UUID = UUID() {
        didSet { persistDrawers() }
    }
    /// 每组独立容量上限覆盖（nil = 跟随全局默认 MaxItemsPolicy）
    @Published private(set) var drawerLimitOverrides: [UUID: MaxItemsPolicy] = [:] {
        didSet { persistDrawerLimits() }
    }

    /// 缩略图缓存（图片/视频真实预览）
    @Published var thumbs: [UUID: NSImage] = [:]
    private var thumbFailed = Set<UUID>()
    /// 正在后台解码的条目：行反复 onAppear（滚动/搜索过滤）时
    /// 避免对同一个大文件并发排多个解码任务
    private var thumbInFlight = Set<UUID>()
    /// 大小文本缓存（按路径）：文件夹的大小要列目录，不能每次渲染都算
    private var sizeTextCache: [String: String] = [:]
    /// 最近一次存在性扫描中，磁盘上已不存在的条目
    /// （展示层据此降透明 + 「文件已不存在」提示；不自动移除）
    @Published private(set) var missingIDs: Set<UUID> = []
    /// 一次存在性扫描进行中（避免重复排队）
    private var missingScanInFlight = false
    /// 扫描进行中又有新请求：扫描完成后自动再扫一轮（合并而不是丢弃）
    private var missingScanPending = false
    /// 设置里重新打开缩略图时，为已经显示过（错过 onAppear）的行补齐
    private var thumbnailSettingCancellable: AnyCancellable?
    /// 设置面板调整清理策略时立即生效（设置承诺「即时生效」）
    private var maintenanceCancellable: AnyCancellable?
    /// 最近一次移除 / 清空的快照；非空时界面显示「还原」toast。
    /// 新的移除会替换旧快照（旧的撤销窗口关闭）。不持久化。
    @Published private(set) var undoSnapshot: RemovalSnapshot?
    /// 轻提示（重复跳过 / 拷贝反馈等非撤销场景）；几秒后自动消失
    @Published private(set) var notice: String?
    private var noticeTask: Task<Void, Never>?
    /// 测试注入：收件箱清扫目录（默认真实 Inbox；测试指向临时目录，避免动到真实数据）
    var inboxDirectoryOverride: URL?

    private var effectiveInboxDirectory: URL {
        inboxDirectoryOverride ?? InboxStore.directory
    }

    private init() {
        // 分组：读取旧值或全新创建；至少保证一个分组存在。
        // （init 内赋值不触发 didSet，末尾显式 persistDrawers）
        if let data = UserDefaults.standard.data(forKey: Self.drawersKey),
           let decoded = try? JSONDecoder().decode([DrawerGroup].self, from: data),
           !decoded.isEmpty {
            drawers = decoded
        } else {
            drawers = [DrawerGroup(name: Self.defaultDrawerName)]
        }
        if let raw = UserDefaults.standard.string(forKey: Self.currentDrawerKey),
           let id = UUID(uuidString: raw),
           drawers.contains(where: { $0.id == id }) {
            currentDrawerID = id
        } else {
            currentDrawerID = drawers[0].id
        }
        // 每组容量覆盖（要在条目按容量收敛前就位）
        if let data = UserDefaults.standard.data(forKey: Self.drawerLimitsKey),
           let saved = try? JSONDecoder().decode([String: Int].self, from: data) {
            drawerLimitOverrides = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in
                guard let id = UUID(uuidString: key), let policy = MaxItemsPolicy(rawValue: value) else { return nil }
                return (id, policy)
            })
        }

        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([ShelfItem].self, from: data) {
            var restored = saved
            let settings = AppSettings.shared
            // 默认只保留仍然存在的文件；可在设置里关闭（保留失效条目，等手动移除）
            if settings.removeMissingOnLaunch {
                restored = restored.filter { FileManager.default.fileExists(atPath: $0.path) }
            }
            restored = Self.pruned(restored, policy: settings.autoClean)
            let loadedLimits = drawerLimitOverrides
            restored = Self.trimmedPerDrawer(restored) { drawerID in
                loadedLimits[drawerID] ?? settings.maxItems
            }
            // 旧版本条目没有 drawerID：归入第一个分组（通常是迁移出的「默认」）
            let fallbackDrawer = drawers[0].id
            for index in restored.indices where restored[index].drawerID == nil {
                restored[index].drawerID = fallbackDrawer
            }
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
        // 容量上限 / 过期清理策略变化 → 立即按新策略收敛现有条目
        maintenanceCancellable = Publishers.Merge(
            AppSettings.shared.$autoClean.dropFirst().map { _ in () },
            AppSettings.shared.$maxItems.dropFirst().map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { _ in
            MainActor.assumeIsolated {
                ShelfStore.shared.applyMaintenancePolicies()
            }
        }
        // 上次会话若带着未还原的快照退出，这里把失去引用的物化文件清掉
        // （测试进程注入临时目录前不清扫，避免动到真实收件箱）
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            settleInbox()
        }
        // init 内赋值不触发 didSet：分组结构落盘一次
        persistDrawers()
        // init 内赋值不触发 didSet：启动时手动扫一遍存在性
        refreshMissingStatus()
    }

    /// 发一条轻提示；自动覆盖上一条，2.2 秒后自动消失
    func postNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    @discardableResult
    func add(urls: [URL]) -> (added: Int, skippedDuplicates: Int) {
        var known = Set(items.map(\.path))
        var newItems: [ShelfItem] = []
        newItems.reserveCapacity(urls.count)
        for url in urls {
            let path = url.standardizedFileURL.path
            // 与已有条目、以及同批次内的重复项一并不重复入列
            guard !known.contains(path) else { continue }
            known.insert(path)
            newItems.append(ShelfItem(url: url, drawerID: currentDrawerID))
        }
        let skipped = urls.count - newItems.count
        guard !newItems.isEmpty else { return (0, skipped) }
        // 一次性追加：一次 didSet = 一次全量编码落盘（逐条 append 是 O(n²) 次写盘）
        items.append(contentsOf: newItems)
        enforceCapacityLimit()
        return (newItems.count, skipped)
    }

    func remove(_ item: ShelfItem) {
        remove([item])
    }

    /// 批量移除（多选 Delete / 清理失效条目共用）：一次快照、一次落盘
    func remove(_ targets: [ShelfItem]) {
        guard !targets.isEmpty else { return }
        recordRemoval(entries: targets.map(initRemovalEntry))
        let ids = Set(targets.map(\.id))
        items.removeAll { ids.contains($0.id) }
        releaseAuxState(ids: ids, paths: Set(targets.map(\.path)))
    }

    /// 手动清理：丢弃硬盘上已不存在的条目（设置面板「立即清理」）
    func removeMissing() {
        let missing = items.filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard !missing.isEmpty else { return }
        recordRemoval(entries: missing.map(initRemovalEntry), summary: "已清理 \(missing.count) 个失效条目")
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            releaseAuxState(ids: Set(missing.map(\.id)), paths: Set(missing.map(\.path)))
            let missingIDs = Set(missing.map(\.id))
            items.removeAll { missingIDs.contains($0.id) }
        }
    }

    /// 「移动到文件夹」/ 重命名后把条目改写为指向新路径（类型随新路径重新识别）
    func updatePath(id: UUID, to url: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let oldPath = items[index].path
        items[index].path = url.standardizedFileURL.path
        items[index].kind = FileKind(url: url)
        thumbs[id] = nil
        thumbFailed.remove(id)
        thumbInFlight.remove(id)
        sizeTextCache.removeValue(forKey: oldPath)
        // 行的 SwiftUI 身份没变（id 相同），onAppear 不会重触发：
        // 这里主动补齐新路径的缩略图，否则瓷片会一直退回类型符号
        ensureThumb(for: items[index])
    }

    /// 重命名条目文件（同目录改名；目标名已存在时自动追加 " 2" 序号）。
    /// 名称未变化视为成功；文件不存在或移动失败返回 false。
    @discardableResult
    func rename(id: UUID, to rawName: String) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        guard FileManager.default.fileExists(atPath: item.path) else { return false }
        guard let newName = InboxStore.sanitize(rawName, maxLength: 120), !newName.isEmpty else { return false }
        guard newName != item.name else { return true }
        let directory = item.url.deletingLastPathComponent()
        // 仅大小写变化：fileExists 在大小写不敏感文件系统上会命中自己，
        // 走去重会把「改大小写」误变出 " 2" 后缀——直接改名即可
        let destination: URL
        if newName.compare(item.name, options: [.caseInsensitive]) == .orderedSame {
            destination = directory.appendingPathComponent(newName)
        } else {
            destination = InboxStore.uniqueSiblingURL(fileName: newName, directory: directory)
        }
        guard destination != item.url else { return true }
        do {
            try FileManager.default.moveItem(at: item.url, to: destination)
            withAnimation(DrawerMotion.smooth) { updatePath(id: id, to: destination) }
            return true
        } catch {
            return false
        }
    }

    /// 导出全部条目到目标文件夹（拷贝；同名自动追加序号）。
    /// 返回 (成功数, 失败数, 跳过数)：失效条目跳过。
    @discardableResult
    func exportAll(to folder: URL) -> (exported: Int, failed: Int, skipped: Int) {
        Self.exportPaths(items.map(\.path), to: folder)
    }

    /// 后台拷贝一批路径到目标文件夹（主线程调用会卡 UI，大文件务必走 detached 任务）
    nonisolated static func exportPaths(
        _ paths: [String],
        to folder: URL
    ) -> (exported: Int, failed: Int, skipped: Int) {
        var exported = 0
        var failed = 0
        var skipped = 0
        for path in paths {
            let source = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                skipped += 1
                continue
            }
            let destination = InboxStore.uniqueSiblingURL(
                fileName: source.lastPathComponent,
                directory: folder
            )
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                exported += 1
            } catch {
                failed += 1
            }
        }
        return (exported, failed, skipped)
    }

    // MARK: 置顶 / 手动排序

    /// 批量置顶/取消：只要有一个未置顶就统一置顶，否则统一取消（访达标签式语义）
    func setPinned(_ pinned: Bool, for ids: Set<UUID>) {
        guard items.contains(where: { ids.contains($0.id) && $0.pinned != pinned }) else { return }
        withAnimation(DrawerMotion.smooth) {
            for index in items.indices where ids.contains(items[index].id) {
                items[index].pinned = pinned
            }
        }
    }

    /// 批量切换置顶态（右键菜单入口）
    func togglePinned(for targets: [ShelfItem]) {
        setPinned(!targets.allSatisfy(\.pinned), for: Set(targets.map(\.id)))
    }

    /// 手动排序：整批平移 offset 行（-1 上移 / +1 下移）。
    /// 移动跳过不同置顶分区的邻居，保证可见顺序真的变化；一次赋值一次落盘。
    func nudge(ids: [UUID], by offset: Int) {
        guard offset == -1 || offset == 1 else { return }
        var next = items
        // 连续同向平移时按行进方向处理，前面的条目腾出位置后面的才能跟上
        let ordered = offset < 0 ? ids : ids.reversed()
        for id in ordered {
            guard let index = next.firstIndex(where: { $0.id == id }) else { continue }
            let pinned = next[index].pinned
            var neighbor = index + offset
            while neighbor >= 0, neighbor < next.count, next[neighbor].pinned != pinned {
                neighbor += offset
            }
            guard neighbor >= 0, neighbor < next.count else { continue }
            let moved = next.remove(at: index)
            next.insert(moved, at: neighbor)
        }
        guard next != items else { return }
        withAnimation(DrawerMotion.smooth) { items = next }
    }

    /// 手动排序：整批（保持 items 内相对顺序）移到最前 / 最后
    func send(ids: [UUID], toFront: Bool) {
        let set = Set(ids)
        guard set.count > 0, items.contains(where: { set.contains($0.id) }) else { return }
        let moved = items.filter { set.contains($0.id) }
        let rest = items.filter { !set.contains($0.id) }
        let next = toFront ? moved + rest : rest + moved
        guard next != items else { return }
        withAnimation(DrawerMotion.smooth) { items = next }
    }

    // MARK: 分组（多抽屉）

    /// 分组结构 + 当前分组持久化
    private func persistDrawers() {
        if let data = try? JSONEncoder().encode(drawers) {
            UserDefaults.standard.set(data, forKey: Self.drawersKey)
        }
        UserDefaults.standard.set(currentDrawerID.uuidString, forKey: Self.currentDrawerKey)
    }

    /// 条目按归一化规则解析所属分组：nil（异常/未迁移）视为第一个分组
    private func resolvedDrawerID(of item: ShelfItem) -> UUID {
        if let id = item.drawerID, drawers.contains(where: { $0.id == id }) { return id }
        return drawers.first?.id ?? currentDrawerID
    }

    var currentDrawer: DrawerGroup? {
        drawers.first { $0.id == currentDrawerID } ?? drawers.first
    }

    var currentDrawerName: String {
        currentDrawer?.name ?? Self.defaultDrawerName
    }

    /// 当前分组的条目（保持 items 顺序）
    var currentItems: [ShelfItem] {
        items(in: currentDrawerID)
    }

    /// 指定分组的条目
    func items(in drawerID: UUID) -> [ShelfItem] {
        items.filter { resolvedDrawerID(of: $0) == drawerID }
    }

    /// 指定分组的条数
    func itemCount(in drawerID: UUID) -> Int {
        items.reduce(0) { count, item in
            count + (resolvedDrawerID(of: item) == drawerID ? 1 : 0)
        }
    }

    /// 切换当前分组
    func switchDrawer(to id: UUID) {
        guard drawers.contains(where: { $0.id == id }) else { return }
        currentDrawerID = id
    }

    /// 新建分组并切换过去；空名 / 重名返回 nil。名字限长 24。
    @discardableResult
    func createDrawer(named rawName: String) -> UUID? {
        let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        guard !name.isEmpty, !drawers.contains(where: { $0.name == name }) else { return nil }
        let group = DrawerGroup(name: name)
        drawers.append(group)
        currentDrawerID = group.id
        return group.id
    }

    /// 重命名分组；空名 / 与其他分组重名忽略
    func renameDrawer(id: UUID, to rawName: String) {
        let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        guard !name.isEmpty,
              !drawers.contains(where: { $0.name == name && $0.id != id }),
              let index = drawers.firstIndex(where: { $0.id == id }) else { return }
        drawers[index].name = name
    }

    /// 删除分组：其条目整体移到剩余的第一个分组；最后一个分组不可删。
    /// 删的是当前分组时切到条目去向分组。
    @discardableResult
    func deleteDrawer(id: UUID) -> Bool {
        guard drawers.count > 1,
              let index = drawers.firstIndex(where: { $0.id == id }) else { return false }
        drawers.remove(at: index)
        let survivor = drawers[0].id
        withAnimation(DrawerMotion.smooth) {
            for itemIndex in items.indices where resolvedDrawerID(of: items[itemIndex]) == id {
                items[itemIndex].drawerID = survivor
            }
        }
        if currentDrawerID == id { currentDrawerID = survivor }
        return true
    }

    /// 条目整批移到另一分组（右键「移动到分组」）
    func moveItems(ids: [UUID], to drawerID: UUID) {
        guard drawers.contains(where: { $0.id == drawerID }) else { return }
        let set = Set(ids)
        guard items.contains(where: { set.contains($0.id) && resolvedDrawerID(of: $0) != drawerID }) else { return }
        withAnimation(DrawerMotion.smooth) {
            for index in items.indices where set.contains(items[index].id) {
                items[index].drawerID = drawerID
            }
        }
    }

    /// 把指向不存在分组的条目收拢到当前分组（还原快照等路径的兜底）
    private func normalizeOrphanDrawerIDs() {
        let valid = Set(drawers.map(\.id))
        guard items.contains(where: { item in
            guard let id = item.drawerID else { return false }
            return !valid.contains(id)
        }) else { return }
        for index in items.indices {
            if let id = items[index].drawerID, !valid.contains(id) {
                items[index].drawerID = currentDrawerID
            }
        }
    }

    // MARK: 分组容量上限（每组可覆盖全局默认）

    /// 覆盖表持久化：[分组ID: 策略rawValue]
    private func persistDrawerLimits() {
        let raw = Dictionary(
            uniqueKeysWithValues: drawerLimitOverrides.map { ($0.key.uuidString, $0.value.rawValue) }
        )
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.drawerLimitsKey)
        }
    }

    /// 某分组的容量覆盖（nil = 跟随全局默认）
    func limitOverride(for drawerID: UUID) -> MaxItemsPolicy? {
        drawerLimitOverrides[drawerID]
    }

    /// 设置 / 清除某分组的容量覆盖（nil 清除），并立即按新策略收敛
    func setLimitOverride(_ policy: MaxItemsPolicy?, for drawerID: UUID) {
        guard drawerLimitOverrides[drawerID] != policy else { return }
        if let policy {
            drawerLimitOverrides[drawerID] = policy
        } else {
            drawerLimitOverrides.removeValue(forKey: drawerID)
        }
        applyMaintenancePolicies()
    }

    /// 生效容量：覆盖优先，否则全局默认
    private func effectiveLimit(for drawerID: UUID) -> MaxItemsPolicy {
        drawerLimitOverrides[drawerID] ?? AppSettings.shared.maxItems
    }

    /// 每组独立容量淘汰（纯函数）：按分组分区，各自按自己的上限淘汰最旧（置顶豁免），
    /// 保留条目按原顺序拼回；drawerID 为 nil 的异常条目共享一个兜底名额池。
    nonisolated static func trimmedPerDrawer(
        _ items: [ShelfItem],
        limitFor: (UUID) -> MaxItemsPolicy
    ) -> [ShelfItem] {
        var buckets: [UUID: [ShelfItem]] = [:]
        for item in items {
            buckets[item.drawerID ?? unassignedDrawerID, default: []].append(item)
        }
        var keep = Set<UUID>()
        for (drawerID, groupItems) in buckets {
            keep.formUnion(trimmed(groupItems, limit: limitFor(drawerID)).map(\.id))
        }
        return items.filter { keep.contains($0.id) }
    }

    // MARK: 维护策略（纯函数，可单测）

    /// 过期自动清理：丢弃加入时间早于策略窗口的条目；置顶条目豁免
    nonisolated static func pruned(_ items: [ShelfItem], policy: AutoCleanPolicy, now: Date = Date()) -> [ShelfItem] {
        guard let days = policy.days else { return items }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return items.filter { $0.pinned || $0.addedAt >= cutoff }
    }

    /// 容量上限：超出时淘汰最早加入的非置顶条目，保留原有相对顺序；置顶条目不占淘汰名额但保留
    nonisolated static func trimmed(_ items: [ShelfItem], limit: MaxItemsPolicy) -> [ShelfItem] {
        guard let maxCount = limit.count, items.count > maxCount else { return items }
        let pinnedCount = items.filter(\.pinned).count
        let budget = Swift.max(0, maxCount - pinnedCount)
        let keep = Set(
            items
                .filter { !$0.pinned }
                .sorted { $0.addedAt > $1.addedAt }
                .prefix(budget)
                .map(\.id)
        )
        return items.filter { $0.pinned || keep.contains($0.id) }
    }

    /// 按当前「过期清理 + 容量上限」策略收敛条目（设置调整时即时调用）
    private func applyMaintenancePolicies() {
        let settings = AppSettings.shared
        let next = Self.trimmedPerDrawer(Self.pruned(items, policy: settings.autoClean), limitFor: effectiveLimit)
        guard next.count != items.count else { return }
        let kept = Set(next.map(\.id))
        let dropped = items.filter { !kept.contains($0.id) }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
            releaseAuxState(ids: Set(dropped.map(\.id)), paths: Set(dropped.map(\.path)))
            items = next
        }
    }

    @MainActor
    private func enforceCapacityLimit() {
        let capped = Self.trimmedPerDrawer(items, limitFor: effectiveLimit)
        if capped.count != items.count {
            let kept = Set(capped.map(\.id))
            let dropped = items.filter { !kept.contains($0.id) }
            releaseAuxState(ids: Set(dropped.map(\.id)), paths: Set(dropped.map(\.path)))
            items = capped
        }
    }

    /// 条目离开抽屉时回收其附属状态（缩略图 / 解码标记 / 大小缓存）
    private func releaseAuxState(ids: Set<UUID>, paths: Set<String>) {
        for id in ids {
            thumbs[id] = nil
            thumbFailed.remove(id)
            thumbInFlight.remove(id)
            missingIDs.remove(id)
        }
        for path in paths {
            sizeTextCache.removeValue(forKey: path)
        }
    }

    // MARK: 失效检测

    /// 后台扫描条目文件存在性（fileExists × n，utility 队列），
    /// 结果回主线程合并；只影响展示，不自动移除条目。
    func refreshMissingStatus() {
        let snapshot = items
        guard !snapshot.isEmpty else {
            if !missingIDs.isEmpty { missingIDs = [] }
            return
        }
        if missingScanInFlight {
            missingScanPending = true
            return
        }
        missingScanInFlight = true
        Task.detached(priority: .utility) {
            let missing = Self.scanMissing(snapshot)
            await ShelfStore.shared.applyMissingScan(missing)
        }
    }

    nonisolated static func scanMissing(_ items: [ShelfItem]) -> Set<UUID> {
        var missing = Set<UUID>()
        for item in items where !FileManager.default.fileExists(atPath: item.path) {
            missing.insert(item.id)
        }
        return missing
    }

    /// 扫描结果落地：只保留仍在列表里的条目（扫描期间列表可能已变化）；
    /// 有挂起请求时自动补扫一轮。
    private func applyMissingScan(_ result: Set<UUID>) {
        missingScanInFlight = false
        let merged = result.intersection(Set(items.map(\.id)))
        if merged != missingIDs { missingIDs = merged }
        if missingScanPending {
            missingScanPending = false
            refreshMissingStatus()
        }
    }

    /// 清空当前分组的条目（菜单「清空」作用域 = 正在看的分组）
    func clear() {
        let targets = currentItems
        guard !targets.isEmpty else { return }
        recordRemoval(entries: targets.map(initRemovalEntry), summary: "已清空「\(currentDrawerName)」（\(targets.count) 个条目）")
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            let ids = Set(targets.map(\.id))
            items.removeAll { ids.contains($0.id) }
        }
        releaseAuxState(
            ids: Set(targets.map(\.id)),
            paths: Set(targets.map(\.path))
        )
    }

    // MARK: 撤销

    /// 记录移除前快照（覆盖旧快照 = 旧撤销窗口关闭）
    private func recordRemoval(entries: [RemovalSnapshot.Entry], summary: String? = nil) {
        guard !entries.isEmpty else { return }
        let previous = undoSnapshot
        undoSnapshot = RemovalSnapshot(
            entries: entries,
            summary: summary ?? (entries.count == 1
                ? "已移除「\(entries[0].item.name)」"
                : "已移除 \(entries.count) 个条目")
        )
        // 旧快照被顶掉：其收件箱文件不再受保护
        if previous != nil { settleInbox() }
    }

    private func initRemovalEntry(_ item: ShelfItem) -> RemovalSnapshot.Entry {
        RemovalSnapshot.Entry(item: item, index: items.firstIndex(where: { $0.id == item.id }) ?? items.count)
    }

    /// 还原最近一次移除：按原位置插回，返回还原条数。
    /// 若还原条目的分组已被删除，收拢到当前分组。
    @discardableResult
    func undoLastRemoval() -> Int {
        guard let snapshot = undoSnapshot else { return 0 }
        undoSnapshot = nil
        let restored = withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            var next = items
            for entry in snapshot.entries.sorted(by: { $0.index < $1.index }) {
                let position = min(entry.index, next.count)
                next.insert(entry.item, at: position)
            }
            items = next
            return snapshot.entries.count
        }
        normalizeOrphanDrawerIDs()
        settleInbox()
        return restored
    }

    /// 放弃还原（toast 超时或用户关闭）
    func discardUndo() {
        guard undoSnapshot != nil else { return }
        undoSnapshot = nil
        settleInbox()
    }

    /// 收件箱清扫：删除不再被任何条目引用（也无待还原快照保护）的物化文件。
    /// 测试进程必须先注入 inboxDirectoryOverride 才允许清扫——
    /// 否则共享 store 上残留的测试快照可能把真实收件箱里的用户数据当垃圾删掉。
    private func settleInbox() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
           inboxDirectoryOverride == nil {
            return
        }
        var referenced = Set(items.map(\.path))
        if let snapshot = undoSnapshot {
            snapshot.entries.forEach { referenced.insert($0.item.path) }
        }
        InboxStore.sweep(referenced: referenced, directory: effectiveInboxDirectory)
    }

    /// 退出前收尾：持久化 + 清扫失去引用的物化文件
    func prepareForTermination() {
        persist()
        settleInbox()
    }

    // MARK: 缩略图

    /// 行首次出现时调用；解码在后台线程进行，完成后自动刷新行。
    /// 条目在解码完成前被移除时，结果会被丢弃（孤儿回调守卫）。
    /// 图片 / 视频 / PDF 先查磁盘缓存（按路径+mtime+大小指纹），未命中才解码。
    func ensureThumb(for item: ShelfItem) {
        guard AppSettings.shared.showThumbnails else { return }
        guard thumbs[item.id] == nil, thumbFailed.contains(item.id) == false else { return }
        guard thumbInFlight.insert(item.id).inserted else { return } // 已在解码，勿重复排队
        guard item.kind.producesThumbnail else {
            thumbInFlight.remove(item.id)
            return
        }
        let variant = item.kind.variant
        let id = item.id
        let url = item.url
        Task.detached(priority: .utility) {
            // 磁盘缓存命中：直接用缓存图（视频抽帧 / PDF 渲染都省掉）
            if let fingerprint = ThumbnailDiskCache.fingerprint(of: url),
               let cached = ThumbnailDiskCache.image(
                   forKey: ThumbnailDiskCache.makeKey(
                       path: url.path,
                       modifiedAt: fingerprint.modifiedAt,
                       fileSize: fingerprint.fileSize
                   )
               ) {
                await ShelfStore.shared.setThumb(cached, for: id)
                return
            }
            let image: NSImage?
            switch variant {
            case .image: image = Self.downsampledImage(url)
            case .video: image = Self.videoThumbnail(url)
            case .pdf:   image = Self.pdfThumbnail(url)
            default:     image = nil
            }
            // 解码成功顺手写回缓存（指纹失效场景下重写最新）
            if let image, let fingerprint = ThumbnailDiskCache.fingerprint(of: url) {
                ThumbnailDiskCache.store(
                    image,
                    forKey: ThumbnailDiskCache.makeKey(
                        path: url.path,
                        modifiedAt: fingerprint.modifiedAt,
                        fileSize: fingerprint.fileSize
                    )
                )
                ThumbnailDiskCache.enforceLimit()
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
        thumbInFlight.remove(id) // 成败都先解除占位，允许将来重试
        guard items.contains(where: { $0.id == id }) else { return }
        if let image {
            thumbs[id] = image
        } else {
            thumbFailed.insert(id)
        }
    }

    /// 渲染路径取大小文本：同一路径只做一次磁盘查询（含列目录），随条目生命周期缓存
    func cachedSizeText(for path: String) -> String {
        if let cached = sizeTextCache[path] { return cached }
        let text = Self.sizeText(for: path)
        sizeTextCache[path] = text
        return text
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
