import AppKit
import SwiftUI
import Quartz
import UniformTypeIdentifiers

// MARK: - 根视图

struct ContentView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var interaction: InteractionModel
    @State private var isDropTargeted = false
    @State private var handleHovered = false
    @FocusState private var searchFocused: Bool

    /// 当前应展示的条目（过滤 + 排序后）
    private var displayedItems: [ShelfItem] {
        interaction.displayItems(from: store.items)
    }

    var body: some View {
        Group {
            if interaction.isCollapsed {
                CollapsedTabView(store: store, interaction: interaction)
                    .transition(.opacity)
            } else {
                expandedContent
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: interaction.isCollapsed)
        .overlay {
            if !interaction.isCollapsed {
                dropHighlight
            }
        }
        .onDrop(
            of: DropFileLoader.typeIdentifiers,
            delegate: DrawerDropDelegate(store: store, interaction: interaction, isTargeted: $isDropTargeted)
        )
        .onAppear { syncFocus() }
        .onChange(of: interaction.searchFocusToken) { syncFocus() }
        .onChange(of: store.items) {
            interaction.reconcileAfterListChange(with: displayedItems)
        }
    }

    /// 展开态：完整抽屉
    private var expandedContent: some View {
        ZStack {
            // 抽屉底色：右侧贴屏幕边缘不圆角，左侧圆角，像从屏幕里抽出来的一格。
            drawerShape
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                // 左缘高光：与收起边条同款工艺——描边 + 水平渐变，跟随圆角不越界；
                // 主色而非纯白，浅色模式同样可见
                .overlay {
                    drawerShape.strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: Color.primary.opacity(0.38), location: 0),
                                .init(color: Color.primary.opacity(0.12), location: 0.04),
                                .init(color: .clear, location: 0.16),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
                }
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.09))
                        .frame(height: 1)
                        .padding(.leading, 22)
                        .allowsHitTesting(false)
                }

            drawerHandle

            VStack(spacing: 0) {
                HeaderView(store: store, interaction: interaction)

                if interaction.isSearchVisible || !interaction.searchText.isEmpty {
                    SearchBarView(interaction: interaction, focused: $searchFocused)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.bottom, 7)
                } else {
                    hairline
                }

                if store.items.isEmpty {
                    Spacer(minLength: 0)
                    EmptyStateView(isTargeted: isDropTargeted)
                    Spacer(minLength: 0)
                } else if displayedItems.isEmpty {
                    NoResultsView(query: interaction.searchText) {
                        withAnimation(.easeOut(duration: 0.18)) { interaction.searchText = "" }
                    }
                } else {
                    itemList(displayedItems)
                }
            }
            .padding(.horizontal, 13)
        }
        .overlay {
            if let item = interaction.selectedItem(in: displayedItems),
               interaction.isPreviewVisible {
                PreviewOverlayView(item: item, store: store, interaction: interaction)
                    .zIndex(10)
            }
        }
    }

    private func syncFocus() {
        guard interaction.isSearchVisible else { return }
        DispatchQueue.main.async { searchFocused = true }
    }

    /// 左缘中部的抽屉拉手：三个小刻度；点击可收起抽屉。
    private var drawerHandle: some View {
        VStack(spacing: 3.5) {
            ForEach(0..<3, id: \.self) { _ in
                Capsule()
                    .fill(Color.primary.opacity(
                        isDropTargeted ? 0.5 : (handleHovered ? 0.45 : 0.22)
                    ))
                    .frame(width: 4, height: 6)
            }
        }
        .frame(width: 13)                                    // 命中区：贴左缘的窄条
        .frame(maxHeight: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .onHover { hovering in
            handleHovered = hovering
            (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .onTapGesture {
            NotificationCenter.default.post(name: .toggleDrawer, object: nil)
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .animation(.easeOut(duration: 0.12), value: handleHovered)
        .help("收起成边条")
        .accessibilityLabel("收起成边条")
        .accessibilityAddTraits(.isButton)
        .frame(maxWidth: .infinity, alignment: .leading)     // 钉在左缘（ZStack 默认居中）
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(height: 1)
            .opacity(store.items.isEmpty ? 0 : 1)
    }

    /// 抽屉身形状：左圆右直（右侧贴屏幕边缘）
    var drawerShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 22,
            bottomLeadingRadius: 22,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    private var dropHighlight: some View {
        drawerShape
            .strokeBorder(Color.accentColor.opacity(isDropTargeted ? 0.85 : 0), lineWidth: 2.5)
        .background(Color.accentColor.opacity(isDropTargeted ? 0.07 : 0))
        .animation(.easeOut(duration: 0.12), value: isDropTargeted)
        .overlay(alignment: .center) {
            if isDropTargeted {
                Label("松开，放入抽屉", systemImage: "plus.view")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(9)
                    .background(Circle().fill(Color.accentColor))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
    }

    private func itemList(_ items: [ShelfItem]) -> some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(items) { item in
                    ItemRow(
                        item: item,
                        store: store,
                        interaction: interaction,
                        isSelected: interaction.selectedID == item.id
                    )
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.94))
                    ))
                }
            }
            .padding(.top, 9)
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - 拖放代理（允许多个文件一次性放入；拖到收起态边条上自动展开）

private struct DrawerDropDelegate: DropDelegate {
    let store: ShelfStore
    let interaction: InteractionModel
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
        revealIfNeeded()
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    /// 收起态时先把抽屉滑出来接住文件（受设置控制）
    private func revealIfNeeded() {
        if interaction.isCollapsed, AppSettings.shared.expandOnDragHover {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                interaction.isCollapsed = false
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        revealIfNeeded()
        let providers = info.itemProviders(for: DropFileLoader.typeIdentifiers)
        guard !providers.isEmpty else { return false }
        DropFileLoader.loadAll(from: providers) { urls in
            guard !urls.isEmpty else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                store.add(urls: urls)
            }
        }
        return true
    }
}

// MARK: - 头部

private struct HeaderView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var interaction: InteractionModel
    @State private var sortHovered = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "tray.full")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.13))
                )

            Text("文件抽屉")
                .font(.system(size: 14, weight: .semibold))
                .kerning(0.2)

            if !store.items.isEmpty {
                Text("\(store.items.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }

            Spacer(minLength: 6)

            HStack(spacing: 3) {
                sortMenu
                HoverCircleButton(
                    systemImage: "magnifyingglass",
                    tip: "搜索（⌘F）",
                    size: 25,
                    tint: interaction.isSearchVisible ? Color.accentColor : .secondary,
                    activeTint: Color.accentColor,
                    activeFill: Color.accentColor.opacity(0.12)
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        interaction.requestSearchFocus()
                    }
                }
                HoverCircleButton(systemImage: "plus", tip: "导入文件", size: 25) {
                    importViaPanel()
                }
                if !store.items.isEmpty {
                    HoldToClearButton()
                }
                HoverCircleButton(systemImage: "gearshape", tip: "设置（⌘,）", size: 25) {
                    SettingsWindowManager.shared.show()
                }
                HoverCircleButton(
                    systemImage: "arrow.right.to.line",
                    tip: "收起成边条",
                    size: 25,
                    activeTint: Color.accentColor,
                    activeFill: Color.accentColor.opacity(0.12)
                ) {
                    NotificationCenter.default.post(name: .toggleDrawer, object: nil)
                }
            }
        }
        .padding(.vertical, 11)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: store.items.count)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(InteractionModel.SortMode.allCases) { mode in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { interaction.sortMode = mode }
                } label: {
                    if interaction.sortMode == mode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(sortHovered ? Color.primary : Color.secondary)
                .frame(width: 25, height: 25)
                .background(
                    Circle().fill(Color.primary.opacity(sortHovered ? 0.09 : 0))
                )
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { sortHovered = hovering }
            (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .help("排序")
    }

    private func importViaPanel() {
        let dlg = NSOpenPanel()
        dlg.canChooseFiles = true
        dlg.canChooseDirectories = true
        dlg.allowsMultipleSelection = true
        dlg.prompt = "放入抽屉"
        if dlg.runModal() == .OK {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                store.add(urls: Array(dlg.urls))
            }
        }
    }
}

/// 悬停时点亮圆形底 + 切换手型光标 + 按压缩放的图标按钮
struct HoverCircleButton: View {
    let systemImage: String
    var tip: String = ""
    var size: CGFloat = 22
    var tint: Color = .secondary
    /// 悬停时的图标色（默认升到 primary）
    var activeTint: Color? = nil
    /// 悬停时的底色（默认中性灰圆底）
    var activeFill: Color? = nil
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: size, height: size)
                .background(Circle().fill(fillColor))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { hovered = hovering }
            // set() 无栈状态切换：视图在悬停中消失也不会卡住光标
            (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .help(tip)
    }

    private var iconColor: Color {
        hovered ? (activeTint ?? .primary) : tint
    }

    private var fillColor: Color {
        hovered ? (activeFill ?? Color.primary.opacity(0.09)) : Color.clear
    }
}

/// 按压缩放反馈
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.86

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

/// 按住不放才会清空，避免误触；红色进度环走满即执行。
private struct HoldToClearButton: View {
    @State private var heldDate: Date?
    @State private var hovered = false

    var body: some View {
        // 仅在按住期间跑逐帧时钟，平时零开销
        Group {
            if heldDate != nil {
                TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                    ring(progress: min(context.date.timeIntervalSince(heldDate ?? .distantFuture) / 0.65, 1))
                }
            } else {
                ring(progress: 0)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { hovered = hovering }
            (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if heldDate == nil { heldDate = Date() }
                }
                .onEnded { _ in
                    defer { heldDate = nil }
                    if min(Date().timeIntervalSince(heldDate ?? .distantFuture) / 0.65, 1) >= 1 {
                        ShelfStore.shared.clear()
                    }
                }
        )
        .accessibilityLabel("按住清空抽屉")
        .help("按住清空抽屉")
    }

    private func ring(progress: Double) -> some View {
        Button(action: {}) {
            ZStack {
                Circle()
                    .fill(hovered && progress == 0
                          ? Color(hex: 0xE0455F).opacity(0.10)
                          : Color.clear)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        Color(hex: 0xE0455F),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(progress > 0 || hovered
                                     ? Color(hex: 0xE0455F)
                                     : Color.secondary)
                    .scaleEffect(progress >= 1 ? 0.82 : 1)
            }
            .frame(width: 25, height: 25)
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - 条目行

private struct ItemRow: View {
    let item: ShelfItem
    let store: ShelfStore
    let interaction: InteractionModel
    let isSelected: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            FileTile(item: item, store: store, size: 38)
                .scaleEffect(hovered ? 1.07 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.6), value: hovered)

            VStack(alignment: .leading, spacing: 2.5) {
                highlightName

                Text(item.metaLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            HStack(spacing: 1) {
                rowAction("folder", "在访达中显示", delay: 0) {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                rowAction("square.and.arrow.down", "另存为…", delay: 0.03) {
                    exportItem()
                }
                rowAction("xmark", "从抽屉移除", delay: 0.06, tint: Color(hex: 0xE0455F).opacity(0.9), activeTint: Color(hex: 0xE0455F)) {
                    removeSelf()
                }
            }
            .opacity(hovered ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.55) : .clear,
                    lineWidth: 1.5
                )
        )
        // 悬停浮起：柔和投影制造"离开列表平面"的层次
        .shadow(
            color: .black.opacity(hovered ? 0.10 : 0),
            radius: hovered ? 8 : 0,
            y: hovered ? 3 : 0
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                hovered = hovering
            }
        }
        // 先注册双击（打开），再注册单击（选中）；SwiftUI 会优先匹配高次数手势。
        .onTapGesture(count: 2) {
            NSWorkspace.shared.open(item.url)
        }
        .onTapGesture { selectRow() }
        .contextMenu {
            Button("打开") { NSWorkspace.shared.open(item.url) }
            Button("快速预览") { interaction.togglePreview(for: item) }
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("另存为…") { exportItem() }
            Divider()
            Button("移除", role: .destructive) { removeSelf() }
        }
        .onDrag { item.dragProvider() }
        .help("单击选中 · 双击打开 · 空格预览")
        .onAppear { store.ensureThumb(for: item) }
    }

    /// 单击行：选中 + 把非激活面板设为 key，让键盘导航（空格/↑↓）可用
    private func selectRow() {
        DrawerPanel.active?.makeKeyAndOrderFront(nil)
        withAnimation(.easeOut(duration: 0.15)) {
            interaction.select(item)
        }
    }

    private var rowFill: Color {
        if isSelected { return Color.accentColor.opacity(hovered ? 0.13 : 0.09) }
        return Color.primary.opacity(hovered ? 0.08 : 0.04)
    }

    /// 搜索命中时高亮名称中的匹配片段
    @ViewBuilder
    private var highlightName: some View {
        let query = interaction.searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if query.isEmpty || !item.name.localizedStandardContains(query) {
            Text(item.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text(highlightedText(item.name, query: query))
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func highlightedText(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        let lowerText = text.lowercased()
        let lowerQuery = query.lowercased()
        var searchStart = lowerText.startIndex
        while let range = lowerText.range(of: lowerQuery, range: searchStart..<lowerText.endIndex) {
            if let attr = Range(range, in: attributed) {
                attributed[attr].foregroundColor = .accentColor
                attributed[attr].font = .system(size: 13, weight: .bold)
            }
            searchStart = range.upperBound
        }
        return attributed
    }

    private func rowAction(
        _ symbol: String,
        _ tip: String,
        delay: Double,
        tint: Color = .secondary,
        activeTint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        HoverCircleButton(
            systemImage: symbol,
            tip: tip,
            size: 21,
            tint: tint,
            activeTint: activeTint
        ) {
            action()
        }
        .opacity(hovered ? 1 : 0)
        .offset(x: hovered ? 0 : 7)
        // 悬停进入时依次错峰滑入；移出时立即一起退场
        .animation(
            .spring(response: 0.3, dampingFraction: 0.75).delay(hovered ? delay : 0),
            value: hovered
        )
    }

    private func exportItem() {
        let dlg = NSSavePanel()
        dlg.nameFieldStringValue = item.name
        dlg.canCreateDirectories = true
        dlg.prompt = "导出"
        if dlg.runModal() == .OK, let dest = dlg.url {
            try? FileManager.default.copyItem(at: item.url, to: dest)
        }
    }

    private func removeSelf() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
            store.remove(item)
        }
    }
}

// MARK: - 收起态：贴右缘的窄边条，点击展开；拖文件上去自动展开接收

private struct CollapsedTabView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var interaction: InteractionModel
    @State private var hovered = false

    private var tabShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 17,
            bottomLeadingRadius: 17,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    var body: some View {
        ZStack {
            tabShape
                .fill(.ultraThinMaterial)
                // 左缘高光：描边 + 水平渐变（亮在左、向右消失），
                // 描边路径天然跟随圆角，不会像直线那样戳出弧线
                .overlay {
                    tabShape.strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: Color.primary.opacity(hovered ? 0.55 : 0.32), location: 0),
                                .init(color: Color.primary.opacity(hovered ? 0.22 : 0.10), location: 0.10),
                                .init(color: .clear, location: 0.30),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
                }
                .overlay {
                    // 拖拽悬停时的接收高亮
                    tabShape
                        .fill(Color.accentColor.opacity(hovered ? 0.10 : 0))
                        .allowsHitTesting(false)
                }

            VStack(spacing: 7) {
                Image(systemName: "tray.full")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(hovered ? Color.primary : Color.accentColor)

                if !store.items.isEmpty {
                    Text("\(store.items.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(tabShape)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { hovered = hovering }
            (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .onTapGesture {
            DrawerPanel.active?.makeKeyAndOrderFront(nil)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
                interaction.isCollapsed = false
            }
        }
        .help("展开抽屉")
        .accessibilityLabel("展开抽屉")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - 搜索栏

private struct SearchBarView: View {
    @ObservedObject var interaction: InteractionModel
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            ZStack(alignment: .leading) {
                if interaction.searchText.isEmpty {
                    Text("搜索抽屉中的文件")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                TextField("", text: $interaction.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
            }

            if !interaction.searchText.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { interaction.searchText = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }

            HoverCircleButton(systemImage: "xmark", tip: "关闭搜索", size: 18) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    interaction.clearSearchAndHideIfNeeded()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            focused.wrappedValue ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.07),
                            lineWidth: 1
                        )
                )
        )
        .focused(focused)
        .animation(.easeOut(duration: 0.15), value: interaction.searchText.isEmpty)
    }
}

// MARK: - 无结果

private struct NoResultsView: View {
    let query: String
    let clearAction: () -> Void

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary.opacity(0.6))
            Text("没有匹配「\(query)」的条目")
                .font(.system(size: 12, weight: .medium))

            Button(action: clearAction) {
                Text("清除搜索")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.13)))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("清除搜索")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }
}

// MARK: - QuickLook 预览弹层

private struct PreviewOverlayView: View {
    let item: ShelfItem
    let store: ShelfStore
    let interaction: InteractionModel

    var body: some View {
        ZStack {
            // 遮罩：点击空白处关闭
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { interaction.closePreview() }

            card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.primary.opacity(0.08))
            QLPreviewRepresentable(url: item.url)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            footerHints
        }
        .frame(height: 384)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.28), radius: 22, y: 8)
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.7)
        )
        .padding(.horizontal, 12)
    }

    private var header: some View {
        HStack(spacing: 7) {
            FileTile(item: item, store: store, size: 20)

            Text(item.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            HoverCircleButton(systemImage: "xmark", tip: "关闭预览（Esc）", size: 19) {
                interaction.closePreview()
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }

    private var footerHints: some View {
        HStack(spacing: 9) {
            hintChip(key: "Space", label: "关闭")
            hintChip(key: "↑ ↓", label: "切换")
            hintChip(key: "⏎", label: "打开")
            Spacer(minLength: 0)
            Text(item.metaLine)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }

    private func hintChip(key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}

/// 原生 QuickLook 视图：视频可直接播放、PDF 可翻页、图片支持缩放
private struct QLPreviewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view: QLPreviewView
        if let created = QLPreviewView(frame: .zero, style: .normal) {
            view = created
        } else {
            view = QLPreviewView()
        }
        view.shouldCloseWithWindow = false
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url {
            view.previewItem = url as NSURL
            view.autostarts = true // 图片/文档直接展示；视频/音频开始预览即播放
        }
    }
}

// MARK: - 文件瓷片：有真实预览（图片/视频/PDF）时展示预览，否则用类型化瓷片
// （同系渐变底 + 品牌色符号 + 扩展名角标，逐格式适配见 FileIconStyle.swift）

struct FileTile: View {
    let item: ShelfItem
    let store: ShelfStore
    var size: CGFloat
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let radius = size * 0.27

        Group {
            if settings.showThumbnails, let thumb = store.thumbs[item.id] {
                thumbnailTile(thumb, radius: radius)
            } else {
                glyphTile(radius: radius)
            }
        }
        .frame(width: size, height: size)
    }

    private func thumbnailTile(_ image: NSImage, radius: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()

            if item.kind.variant == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.19, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(size * 0.09)
                    .background(
                        Circle()
                            .fill(.black.opacity(0.55))
                            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    )
                    .padding(size * 0.08)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func glyphTile(radius: CGFloat) -> some View {
        let style = item.kind.style
        // 小尺寸（预览弹层头部 20pt）放不下角标，只在行内 38pt 瓷片上显示
        let badge = size >= 30 ? style.badge : nil
        let iconSize = size * (badge == nil ? 0.42 : 0.34)

        return ZStack {
            // 同系渐变底：左上亮右下暗；透明度让明暗模式共用一套色值
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: style.color.opacity(0.30), location: 0),
                            .init(color: style.color.opacity(0.13), location: 1),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )

            // 顶部微光，加一点玻璃质感
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.20), location: 0),
                            .init(color: Color.white.opacity(0), location: 0.55),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            VStack(spacing: size * 0.05) {
                Image(systemName: style.symbolName)
                    .font(.system(size: iconSize, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(style.color)

                if let badge {
                    Text(badge)
                        .font(.system(size: max(6, size * 0.17), weight: .semibold, design: .monospaced))
                        .foregroundStyle(style.color)
                        .padding(.horizontal, size * 0.055)
                        .padding(.vertical, size * 0.018)
                        .background(Capsule().fill(style.color.opacity(0.13)))
                        .overlay(Capsule().strokeBorder(style.color.opacity(0.25), lineWidth: 0.5))
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(style.color.opacity(0.22), lineWidth: 0.7)
        )
    }
}

// MARK: - 空态

struct EmptyStateView: View {
    var isTargeted: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: isTargeted)) { context in
            let drift = isTargeted ? 0 : sin(context.date.timeIntervalSinceReferenceDate / 3 * 2 * .pi) * 3

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.05))
                    Circle()
                        .strokeBorder(
                            isTargeted ? Color.accentColor : Color.primary.opacity(0.09),
                            lineWidth: isTargeted ? 2 : 1
                        )
                    Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "tray")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.75))
                }
                .frame(width: 62, height: 62)
                .scaleEffect(isTargeted ? 1.1 : 1)
                .offset(y: drift)

                VStack(spacing: 5) {
                    Text(isTargeted ? "松开，放进抽屉" : "把文件放进来")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isTargeted ? Color.accentColor : Color.primary.opacity(0.85))

                    Text(isTargeted
                         ? "支持一次拖入多个文件"
                         : "从访达拖入任何文件或文件夹\n需要时再原样拖出去")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3.5)
                }
            }
            .padding(.horizontal, 24)
            .animation(.spring(response: 0.35, dampingFraction: 0.65), value: isTargeted)
        }
        .padding(.bottom, 28)
    }
}
