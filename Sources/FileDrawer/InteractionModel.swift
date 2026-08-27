import SwiftUI

// MARK: - 交互模型：选中 / 搜索 / 排序 / 预览

@MainActor
final class InteractionModel: ObservableObject {
    static let shared = InteractionModel()
    // 排序覆盖用独立 key 而非并入 ShelfPersistence v3 容器：
    // 排序是 UI 偏好（InteractionModel 域）而非抽屉数据（ShelfStore 域），
    // 并入会制造跨对象耦合与初始化顺序风险（见 README·实现要点·多抽屉分组条目）。
    // 分组删除时由 ShelfStore.deleteDrawer 调 resetSortMode 清理，不留孤儿映射。
    private static let sortDefaultsKey = "com.wangxiao.filedrawer.sortMode"
    private static let perDrawerSortKey = "com.wangxiao.filedrawer.sortModes.v2"

    enum SortMode: Int, CaseIterable, Identifiable {
        case timeNewestFirst = 0
        case timeOldestFirst = 1
        case nameAscending = 2
        case kindThenName = 3
        case manual = 4
        var id: Int { rawValue }

        var label: String {
            switch self {
            case .timeNewestFirst: return L10n.t("最近加入在前")
            case .timeOldestFirst: return L10n.t("最早加入在前")
            case .nameAscending:   return L10n.t("按名称 A–Z")
            case .kindThenName:    return L10n.t("按类型分组")
            case .manual:          return L10n.t("手动顺序")
            }
        }

        var symbol: String {
            switch self {
            case .timeNewestFirst: return "arrow.down"
            case .timeOldestFirst: return "arrow.up"
            case .nameAscending:   return "textformat.abc"
            case .kindThenName:    return "square.grid.2x2"
            case .manual:          return "hand.raised"
            }
        }
    }

    @Published var searchText = "" {
        didSet {
            // 截断超长输入；仅在真正变化时回写，避免 didSet 无限递归
            let capped = String(searchText.prefix(60))
            if capped != searchText {
                searchText = capped
            } else if oldValue != searchText {
                scheduleContentSearch()
            }
        }
    }
    /// Spotlight 内容命中的条目（名称未命中但内容命中），并入搜索结果
    @Published var contentMatchIDs: Set<UUID> = []
    /// 内容搜索防抖任务
    private var contentSearchTask: Task<Void, Never>?

    /// 搜索词变化 → 清旧结果并防抖起一次 Spotlight 内容搜索
    private func scheduleContentSearch() {
        contentSearchTask?.cancel()
        contentMatchIDs = []
        let raw = searchText
        guard SpotlightContentSearch.shouldSearch(raw, enabled: AppSettings.shared.searchFileContents) else { return }
        contentSearchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else { return }
            let paths = await SpotlightContentSearch.shared.searchPaths(matching: raw)
            guard !Task.isCancelled else { return }
            // 与全部条目按路径求交（内容命中可跨分组，搜索作用于当前分组的展示管线）
            let hits = ShelfStore.shared.items
                .filter { paths.contains($0.path) }
                .map(\.id)
            guard !hits.isEmpty else { return }
            self.contentMatchIDs = Set(hits)
        }
    }
    @Published var isSearchVisible = false
    /// 默认排序：没有单独设置的分组（以及新建分组）用它；设置面板可改
    @Published var defaultSortMode: SortMode {
        didSet { UserDefaults.standard.set(defaultSortMode.rawValue, forKey: Self.sortDefaultsKey) }
    }
    /// 各分组的独立排序覆盖（分组成员自己的排序选择）
    @Published private var drawerSortOverrides: [UUID: SortMode] = [:] {
        didSet { persistDrawerSortOverrides() }
    }

    /// 某分组的生效排序：有单独设置用之，否则回退默认
    func sortMode(for drawerID: UUID) -> SortMode {
        drawerSortOverrides[drawerID] ?? defaultSortMode
    }

    /// 为分组设置独立排序
    func setSortMode(_ mode: SortMode, for drawerID: UUID) {
        drawerSortOverrides[drawerID] = mode
    }

    /// 撤销某分组的独立排序（回到默认）
    func resetSortMode(for drawerID: UUID) {
        drawerSortOverrides.removeValue(forKey: drawerID)
    }

    private func persistDrawerSortOverrides() {
        let raw = Dictionary(uniqueKeysWithValues: drawerSortOverrides.map { ($0.key.uuidString, $0.value.rawValue) })
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.perDrawerSortKey)
        }
    }
    /// 多选集合：当前所有选中的条目；空 = 无选中
    @Published var selectedIDs: Set<UUID> = []
    /// 锚点：最近一次单击的条目（⇧ 点击的区间起点、空格预览 / 键盘导航的对象）。
    /// 直接对它赋值会把多选收敛为单选（保持既有单选语义与测试兼容）。
    @Published var selectedID: UUID? {
        didSet {
            guard oldValue != selectedID else { return }
            if let id = selectedID {
                if !selectedIDs.contains(id) { selectedIDs = [id] }
            } else {
                selectedIDs = []
            }
        }
    }
    @Published var isPreviewVisible = false
    /// 收起态：抽屉缩成贴右缘的窄边条
    @Published var isCollapsed = false {
        didSet {
            guard oldValue != isCollapsed else { return }
            onCollapseChange?(isCollapsed)
        }
    }
    /// AppDelegate 注入：收起/展开时驱动窗口边框动画
    var onCollapseChange: ((Bool) -> Void)?
    /// 递增 token：让搜索框聚焦的时机可控（Cmd+F / 点放大镜）
    @Published var searchFocusToken = 0
    /// 行内拖拽排序：当前悬停的目标行（插入指示条），无拖拽时为 nil
    @Published var reorderTargetID: UUID?

    /// 测试可直接构造独立实例；应用代码使用 shared
    init() {
        let raw = UserDefaults.standard.integer(forKey: Self.sortDefaultsKey)
        defaultSortMode = SortMode(rawValue: raw) ?? .timeNewestFirst
        if let data = UserDefaults.standard.data(forKey: Self.perDrawerSortKey),
           let saved = try? JSONDecoder().decode([String: Int].self, from: data) {
            drawerSortOverrides = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in
                guard let id = UUID(uuidString: key), let mode = SortMode(rawValue: value) else { return nil }
                return (id, mode)
            })
        }
    }

    // MARK: 纯函数（可单测，无隔离）

    /// 搜索词解析：`kind:图片 swift` → 类型过滤 + 名称关键字（多个关键字取交集）
    struct SearchQuery: Equatable {
        var keywords: [String] = []
        var variants: Set<FileKind.Variant> = []

        var isEmpty: Bool { keywords.isEmpty && variants.isEmpty }
    }

    /// kind: 关键字 → 类型（中英文别名）
    nonisolated static func variant(forKindKeyword raw: String) -> FileKind.Variant? {
        let keyword = raw.lowercased()
        let aliases: [(FileKind.Variant, [String])] = [
            (.folder, ["folder", "文件夹", "目录", "dir"]),
            (.image, ["image", "图片", "照片", "photo", "img"]),
            (.video, ["video", "视频", "影片", "movie"]),
            (.audio, ["audio", "音频", "音乐", "music", "sound"]),
            (.pdf, ["pdf"]),
            (.document, ["document", "doc", "文档", "文本", "text"]),
            (.spreadsheet, ["spreadsheet", "sheet", "表格", "excel"]),
            (.presentation, ["presentation", "slides", "演示", "ppt", "keynote"]),
            (.code, ["code", "代码", "source", "源码"]),
            (.design, ["design", "设计"]),
            (.font, ["font", "字体"]),
            (.archive, ["archive", "压缩", "压缩包", "zip", "归档"]),
            (.other, ["other", "其他"]),
        ]
        for (variant, words) in aliases where words.contains(keyword) {
            return variant
        }
        return nil
    }

    /// 解析搜索词：kind: 前缀 token 进类型过滤，其余 token 是名称关键字
    nonisolated static func parseQuery(_ raw: String) -> SearchQuery {
        var query = SearchQuery()
        for token in raw.split(whereSeparator: { $0.isWhitespace }) {
            let word = String(token)
            let lower = word.lowercased()
            if lower.hasPrefix("kind:"), let variant = variant(forKindKeyword: String(lower.dropFirst(5))) {
                query.variants.insert(variant)
            } else if lower.hasPrefix("type:"), let variant = variant(forKindKeyword: String(lower.dropFirst(5))) {
                query.variants.insert(variant)
            } else {
                query.keywords.append(word)
            }
        }
        return query
    }

    nonisolated static func filter(
        _ items: [ShelfItem],
        query: String,
        contentMatched: Set<UUID> = []
    ) -> [ShelfItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        let parsed = parseQuery(trimmed)
        guard !parsed.isEmpty else { return items }
        return items.filter { item in
            guard parsed.variants.isEmpty || parsed.variants.contains(item.kind.variant) else { return false }
            // 名称命中：全部关键字都要落在名称里；内容命中作为回退（Spotlight 结果）
            for keyword in parsed.keywords where !item.name.localizedStandardContains(keyword) {
                return !parsed.keywords.isEmpty && contentMatched.contains(item.id)
            }
            return true
        }
    }

    nonisolated static func sorted(_ items: [ShelfItem], by mode: SortMode) -> [ShelfItem] {
        switch mode {
        case .timeNewestFirst:
            return items.sorted { $0.addedAt > $1.addedAt }
        case .timeOldestFirst:
            return items.sorted { $0.addedAt < $1.addedAt }
        case .nameAscending:
            return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .kindThenName:
            return items.sorted {
                $0.kind.variantSortRank != $1.kind.variantSortRank
                    ? $0.kind.variantSortRank < $1.kind.variantSortRank
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .manual:
            return items // 数组顺序即手动顺序
        }
    }

    /// 展示管线：过滤（名称 + Spotlight 内容回退）→ 置顶分区 → 各分区按指定排序
    func displayItems(from items: [ShelfItem], sort: SortMode) -> [ShelfItem] {
        let filtered = Self.filter(items, query: searchText, contentMatched: contentMatchIDs)
        // 置顶条目永远浮在最前；置顶 / 普通两组内部各自按当前排序
        let pinned = Self.sorted(filtered.filter(\.pinned), by: sort)
        let rest = Self.sorted(filtered.filter { !$0.pinned }, by: sort)
        return pinned + rest
    }

    /// 便捷重载：按默认排序（测试与无分组上下文的调用方使用）
    func displayItems(from items: [ShelfItem]) -> [ShelfItem] {
        displayItems(from: items, sort: defaultSortMode)
    }

    // MARK: 选择与预览

    func selectedItem(in displayed: [ShelfItem]) -> ShelfItem? {
        guard let id = selectedID else { return nil }
        return displayed.first { $0.id == id }
    }

    /// 全部选中的条目（按展示顺序）
    func selectedItems(in displayed: [ShelfItem]) -> [ShelfItem] {
        guard !selectedIDs.isEmpty else { return [] }
        return displayed.filter { selectedIDs.contains($0.id) }
    }

    func select(_ item: ShelfItem?) {
        guard let item else {
            selectedID = nil
            return
        }
        selectedIDs = [item.id]
        selectedID = item.id
    }

    /// ⌘点击：切换某条目的选中态，锚点跟随最后操作的条目
    func toggleSelect(_ item: ShelfItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
            if selectedID == item.id { selectedID = selectedIDs.first }
        } else {
            selectedIDs.insert(item.id)
            selectedID = item.id
        }
    }

    /// ⇧点击：选中锚点到该条目之间的连续区间（锚点保持不变）
    func extendSelection(to item: ShelfItem, within displayed: [ShelfItem]) {
        guard let anchorID = selectedID,
              let anchorIndex = displayed.firstIndex(where: { $0.id == anchorID }),
              let targetIndex = displayed.firstIndex(where: { $0.id == item.id }) else {
            select(item)
            return
        }
        selectedIDs = Set(displayed[min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)].map(\.id))
    }

    /// ⌘A：全选当前展示的条目；锚点尽量保持，否则落到第一条
    func selectAll(in displayed: [ShelfItem]) {
        selectedIDs = Set(displayed.map(\.id))
        if let anchor = selectedID, !selectedIDs.contains(anchor) {
            selectedID = displayed.first?.id
        }
    }

    /// 右键菜单 / 行内按钮的操作目标：
    /// 行本身在多选集合里 → 对整个集合生效（访达语义）；否则只有该行
    func selectionTargets(containing item: ShelfItem, in all: [ShelfItem]) -> [ShelfItem] {
        if selectedIDs.contains(item.id), selectedIDs.count > 1 {
            return all.filter { selectedIDs.contains($0.id) }
        }
        return [item]
    }

    /// 方向键移动选中项；到达边界时停住。移动后收敛为单选。返回新的选中项。
    @discardableResult
    func moveSelection(by step: Int, within displayed: [ShelfItem]) -> ShelfItem? {
        guard !displayed.isEmpty else {
            selectedID = nil
            return nil
        }
        let index = displayed.firstIndex { $0.id == selectedID } ?? (step > 0 ? -1 : displayed.count)
        let next = min(max(index + step, 0), displayed.count - 1)
        // 键盘导航收敛为单选（访达语义）：先设集合再挪锚点，避免 didSet 的
        // 「集合内锚点移动保持集合」分支把多选留下来
        selectedIDs = [displayed[next].id]
        selectedID = displayed[next].id
        return displayed[next]
    }

    func togglePreview(for item: ShelfItem?) {
        guard let item, FileManager.default.fileExists(atPath: item.path) else {
            isPreviewVisible = false
            return
        }
        selectedID = item.id
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
            isPreviewVisible.toggle()
        }
    }

    func closePreview() {
        guard isPreviewVisible else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            isPreviewVisible = false
        }
    }

    func requestSearchFocus() {
        isSearchVisible = true
        searchFocusToken += 1
    }

    func clearSearchAndHideIfNeeded() {
        searchText = ""
        isSearchVisible = false
    }

    /// 条目被移除后调用：选中/预览指向失效时自动收回。
    func reconcileAfterListChange(with displayed: [ShelfItem]) {
        let visible = Set(displayed.map(\.id))
        if !selectedIDs.isEmpty {
            let trimmed = selectedIDs.intersection(visible)
            if trimmed != selectedIDs { selectedIDs = trimmed }
        }
        if let id = selectedID, !visible.contains(id) {
            // 锚点失效：多选集合还在就保持集合、把锚点挪到集合内第一条；否则单选第一条
            if let fallback = selectedIDs.first {
                selectedID = fallback
            } else {
                selectedID = displayed.first?.id
            }
        }
        if isPreviewVisible && selectedItem(in: displayed) == nil {
            closePreview()
        }
    }
}

// MARK: - FileKind 排序辅助

extension FileKind {
    var variantSortRank: Int {
        switch variant {
        case .folder:        return 0
        case .pdf:           return 1
        case .document:      return 2
        case .spreadsheet:   return 3
        case .presentation:  return 4
        case .image:         return 5
        case .video:         return 6
        case .audio:         return 7
        case .code:          return 8
        case .design:        return 9
        case .font:          return 10
        case .archive:       return 11
        case .other:         return 12
        }
    }
}
