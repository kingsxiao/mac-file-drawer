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
    /// 当前选中的条目（单击选中；空格预览、回车打开、方向键移动）
    @Published var selectedID: UUID?
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

    func select(_ item: ShelfItem?) {
        selectedID = item?.id
    }

    /// 方向键移动选中项；到达边界时停住。返回新的选中项。
    @discardableResult
    func moveSelection(by step: Int, within displayed: [ShelfItem]) -> ShelfItem? {
        guard !displayed.isEmpty else {
            selectedID = nil
            return nil
        }
        let index = displayed.firstIndex { $0.id == selectedID } ?? (step > 0 ? -1 : displayed.count)
        let next = min(max(index + step, 0), displayed.count - 1)
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
        if let id = selectedID, !displayed.contains(where: { $0.id == id }) {
            selectedID = displayed.first?.id
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
