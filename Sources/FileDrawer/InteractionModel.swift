import SwiftUI

// MARK: - 交互模型：选中 / 搜索 / 排序 / 预览

@MainActor
final class InteractionModel: ObservableObject {
    static let shared = InteractionModel()
    private static let sortDefaultsKey = "com.wangxiao.filedrawer.sortMode"

    enum SortMode: Int, CaseIterable, Identifiable {
        case timeNewestFirst = 0
        case timeOldestFirst = 1
        case nameAscending = 2
        case kindThenName = 3
        var id: Int { rawValue }

        var label: String {
            switch self {
            case .timeNewestFirst: return "最近加入在前"
            case .timeOldestFirst: return "最早加入在前"
            case .nameAscending:   return "按名称 A–Z"
            case .kindThenName:    return "按类型分组"
            }
        }

        var symbol: String {
            switch self {
            case .timeNewestFirst: return "arrow.down"
            case .timeOldestFirst: return "arrow.up"
            case .nameAscending:   return "textformat.abc"
            case .kindThenName:    return "square.grid.2x2"
            }
        }
    }

    @Published var searchText = "" {
        didSet {
            // 截断超长输入；仅在真正变化时回写，避免 didSet 无限递归
            let capped = String(searchText.prefix(60))
            if capped != searchText {
                searchText = capped
            }
        }
    }
    @Published var isSearchVisible = false
    @Published var sortMode: SortMode {
        didSet { UserDefaults.standard.set(sortMode.rawValue, forKey: Self.sortDefaultsKey) }
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

    /// 测试可直接构造独立实例；应用代码使用 shared
    init() {
        let raw = UserDefaults.standard.integer(forKey: Self.sortDefaultsKey)
        sortMode = SortMode(rawValue: raw) ?? .timeNewestFirst
    }

    // MARK: 纯函数（可单测，无隔离）

    nonisolated static func filter(_ items: [ShelfItem], query: String) -> [ShelfItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { $0.name.localizedStandardContains(trimmed) }
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
        }
    }

    func displayItems(from items: [ShelfItem]) -> [ShelfItem] {
        Self.sorted(Self.filter(items, query: searchText), by: sortMode)
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
