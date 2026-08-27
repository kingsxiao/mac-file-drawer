import AppKit
import SwiftUI
import Quartz
import UniformTypeIdentifiers

// MARK: - 根视图

struct ContentView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var interaction: InteractionModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var isDropTargeted = false
    @State private var handleHovered = false
    /// 抽屉展开后的短时间「入场窗口」：窗口内出现的条目按序错峰滑入
    @State private var entranceWindowActive = false
    /// 入场窗口的代际：快速收起再展开时，旧定时器无权关闭新一轮入场
    @State private var entranceGeneration = 0
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
            collapseIfEmptyAfterRemoval()
        }
    }

    /// 设置开启「清空后自动收起」且抽屉刚被清空时，滑回收起边条
    private func collapseIfEmptyAfterRemoval() {
        guard settings.collapseWhenEmpty,
              store.items.isEmpty,
              !interaction.isCollapsed else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard store.items.isEmpty, !interaction.isCollapsed else { return }
            NotificationCenter.default.post(name: .toggleDrawer, object: nil)
        }
    }

    /// 展开态：完整抽屉
    private var expandedContent: some View {
        ZStack {
            // 抽屉底色：贴屏幕边缘的一侧不圆角，另一侧圆角，像从屏幕里抽出来的一格。
            drawerShape
                .fill(settings.material.material)
                .ignoresSafeArea()
                // 贴边对侧的高光：描边 + 水平渐变，跟随圆角不越界；
                // 主色而非纯白，浅色模式同样可见
                .overlay {
                    drawerShape.strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: Color.primary.opacity(0.38), location: 0),
                                .init(color: Color.primary.opacity(0.12), location: 0.04),
                                .init(color: .clear, location: 0.16),
                            ],
                            startPoint: settings.edge == .right ? .leading : .trailing,
                            endPoint: settings.edge == .right ? .trailing : .leading
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
                }
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.09))
                        .frame(height: 1)
                        .padding(edgeInsetEdge, 26)
                        .allowsHitTesting(false)
                }
                // 品牌光晕：顶部一抹极淡的靛紫，向下三分之一处消失——抽屉的身份色
                .overlay {
                    drawerShape
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: DrawerTheme.accent.opacity(0.10), location: 0),
                                    .init(color: DrawerTheme.accent.opacity(0.03), location: 0.16),
                                    .init(color: .clear, location: 0.34),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
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
            .padding(edgeInsetEdge, 26)                          // 贴边对侧给拉手胶囊留出 gutter
            .padding(oppositeEdge, 13)
        }
        .overlay {
            if let item = interaction.selectedItem(in: displayedItems),
               interaction.isPreviewVisible {
                PreviewOverlayView(item: item, store: store, interaction: interaction)
                    .zIndex(10)
            }
        }
        .overlay(alignment: .bottom) {
            if let snapshot = store.undoSnapshot {
                UndoToastView(summary: snapshot.summary) {
                    store.undoLastRemoval()
                } onDismiss: {
                    store.discardUndo()
                }
                .id(snapshot.summary + String(snapshot.entries.count))
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(20)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.undoSnapshot)
        .onAppear { beginEntranceWindow() }
    }

    /// 展开（或首次出现）后 0.9 秒内启用条目错峰入场；之后出现的行（如搜索回填）直接就位
    private func beginEntranceWindow() {
        entranceWindowActive = true
        entranceGeneration += 1
        let generation = entranceGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard entranceGeneration == generation else { return }
            entranceWindowActive = false
        }
    }

    /// 拉手所在的边（贴边侧的对侧）：右缘停靠时在左
    private var edgeInsetEdge: Edge.Set {
        settings.edge == .right ? .leading : .trailing
    }

    private var oppositeEdge: Edge.Set {
        settings.edge == .right ? .trailing : .leading
    }

    private func syncFocus() {
        guard interaction.isSearchVisible else { return }
        DispatchQueue.main.async { searchFocused = true }
    }

    /// 贴边对侧中部的抽屉拉手：胶囊底 + 三枚横向刻度（中间长、两端短），
    /// 悬停时点亮为品牌渐变并向屏幕外缘轻移，示意"把抽屉推回去"；点击收起。
    private var drawerHandle: some View {
        Button {
            NotificationCenter.default.post(name: .toggleDrawer, object: nil)
        } label: {
            VStack(spacing: 3.5) {
                ForEach(0..<3, id: \.self) { line in
                    Capsule()
                        .fill(handleLineColor(line))
                        .frame(width: line == 1 ? 11 : 7, height: 2.2)
                }
            }
            .scaleEffect(x: handleHovered ? 1.12 : 1, y: handleHovered ? 1.06 : 1)
            .offset(x: handleHovered ? (settings.edge == .right ? 1.5 : -1.5) : 0)
            .frame(width: 19, height: 48)
            .background(
                Capsule().fill(Color.primary.opacity(handleHovered ? 0.12 : 0.07))
            )
            .overlay(
                Capsule().strokeBorder(
                    handleHovered ? DrawerTheme.accent.opacity(0.35) : Color.primary.opacity(0.11),
                    lineWidth: 1
                )
            )
            .frame(width: 26, height: 60)                 // 命中区：胶囊外扩一圈
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.92))
        .onHover { hovering in
            handleHovered = hovering
            (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: handleHovered)
        .help("收起成边条")
        .accessibilityLabel("收起成边条")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: settings.edge == .right ? .leading : .trailing)
    }

    /// 刻度线颜色：默认三级灰；悬停/拖入时切换为品牌渐变，视觉上"握住抽屉"
    private func handleLineColor(_ line: Int) -> Color {
        let base: Double = isDropTargeted ? 0.65 : (handleHovered ? 0.85 : 0.5)
        let shade = line == 1 ? base : base * 0.72
        if handleHovered || isDropTargeted {
            return line == 1
                ? DrawerTheme.accent.opacity(min(shade + 0.15, 1))
                : DrawerTheme.accent.opacity(shade)
        }
        return Color.primary.opacity(shade)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(height: 1)
            .opacity(store.items.isEmpty ? 0 : 1)
    }

    /// 抽屉身形状：贴边对侧圆角、贴边侧直角（右侧停靠时左圆右直）
    var drawerShape: UnevenRoundedRectangle {
        let radius: CGFloat = 22
        return settings.edge == .right
            ? UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: radius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
            : UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: radius,
                topTrailingRadius: radius,
                style: .continuous
            )
    }

    /// 拖入悬停反馈：品牌色描边 + 向前流动的虚线（dashPhase 随时间推进），像传送带一样"接住"文件。
    private var dropHighlight: some View {
        drawerShape
            .fill(DrawerTheme.accent.opacity(isDropTargeted ? 0.07 : 0))
            .overlay {
                if isDropTargeted {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        // 一个 dash 周期 12+8=20pt；24pt/s 匀速流动
                        let phase = (context.date.timeIntervalSinceReferenceDate * 24)
                            .truncatingRemainder(dividingBy: 20)
                        drawerShape.strokeBorder(
                            DrawerTheme.accent.opacity(0.9),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [12, 8], dashPhase: phase)
                        )
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.14), value: isDropTargeted)
            .overlay(alignment: .center) {
                if isDropTargeted {
                    Label("松开，放入抽屉", systemImage: "plus.view")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(9)
                        .background(Circle().fill(DrawerTheme.accentGradient))
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.8))
                        .shadow(color: DrawerTheme.accent.opacity(0.55), radius: 12, y: 3)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .allowsHitTesting(false)
    }

    private func itemList(_ items: [ShelfItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: settings.compactRows ? 4 : 6) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ItemRow(
                            item: item,
                            store: store,
                            interaction: interaction,
                            isSelected: interaction.selectedIDs.contains(item.id),
                            entranceIndex: index,
                            staggerEntrance: entranceWindowActive
                        )
                        .transition(.asymmetric(
                            insertion: .move(edge: settings.edge == .right ? .trailing : .leading).combined(with: .opacity),
                            removal: .opacity.combined(with: .scale(scale: 0.94))
                        ))
                    }
                }
                .padding(.top, settings.compactRows ? 7 : 9)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            // 键盘 ↑↓ 移动选中时，选中行平滑滚入视野
            .onChange(of: interaction.selectedID) {
                guard let id = interaction.selectedID else { return }
                withAnimation(DrawerMotion.smooth) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
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
        HStack(spacing: 7) {
            Image(systemName: "tray.full")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.8)
                )

            Text("文件抽屉")
                .font(.system(size: 14, weight: .semibold))
                .kerning(0.2)
                .lineLimit(1)

            if !store.items.isEmpty {
                Text("\(store.items.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.10)))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }

            if interaction.selectedIDs.count > 1 {
                Text("已选 \(interaction.selectedIDs.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DrawerTheme.accentGradient))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }

            Spacer(minLength: 4)

            HStack(spacing: 3) {
                sortMenu
                HoverCircleButton(
                    systemImage: "magnifyingglass",
                    tip: "搜索（⌘F）",
                    size: 25,
                    tint: interaction.isSearchVisible ? DrawerTheme.accent : .secondary,
                    activeTint: DrawerTheme.accent,
                    activeFill: DrawerTheme.accent.opacity(0.12)
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        interaction.requestSearchFocus()
                    }
                }
                HoverCircleButton(systemImage: "gearshape", tip: "设置（⌘,）", size: 25) {
                    SettingsWindowManager.shared.show()
                }
                HoverCircleButton(
                    systemImage: "arrow.right.to.line",
                    tip: "收起成边条",
                    size: 25,
                    activeTint: DrawerTheme.accent,
                    activeFill: DrawerTheme.accent.opacity(0.12)
                ) {
                    NotificationCenter.default.post(name: .toggleDrawer, object: nil)
                }
            }
        }
        .padding(.vertical, 11)
        .animation(DrawerMotion.bouncy, value: store.items.count)
        .animation(DrawerMotion.bouncy, value: interaction.selectedIDs.count)
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
                .scaleEffect(hovered ? 1.1 : 1)
                .frame(width: size, height: size)
                .background(Circle().fill(fillColor))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.26, dampingFraction: 0.7)) { hovered = hovering }
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

// MARK: - 条目行

private struct ItemRow: View {
    let item: ShelfItem
    let store: ShelfStore
    let interaction: InteractionModel
    let isSelected: Bool
    /// 列表中的序号：首屏/展开时按它错峰滑入
    var entranceIndex: Int = 0
    /// 是否处于抽屉展开后的入场窗口（仅此时错峰滑入）
    var staggerEntrance: Bool = false
    @ObservedObject private var settings = AppSettings.shared
    @State private var hovered = false
    /// 首屏错峰入场（从贴边侧滑入淡入）
    @State private var entered = false
    /// 刚拖入的新条目：行底扫过一道品牌色光
    @State private var appearGlow = false

    /// 是否为"刚刚加入"的条目（区分首屏恢复与新拖入，两者动效不同）
    private var isFreshArrival: Bool {
        Date().timeIntervalSince(item.addedAt) < 1.2
    }

    var body: some View {
        HStack(spacing: settings.compactRows ? 8 : 10) {
            FileTile(item: item, store: store, size: tileSize)
                .overlay(alignment: .topLeading) {
                    if item.pinned {
                        // 置顶角标：品牌色小图钉，压在瓷片左上角
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Circle().fill(DrawerTheme.accentGradient))
                            .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 0.6))
                            .offset(x: -3, y: -3)
                            .help("已置顶 · 免于自动清理")
                    }
                }
                .scaleEffect(hovered ? 1.07 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.6), value: hovered)

            VStack(alignment: .leading, spacing: settings.compactRows ? 1.5 : 2.5) {
                highlightName

                if !metaLine.isEmpty {
                    Text(metaLine)
                        .font(.system(size: settings.compactRows ? 10.5 : 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 1) {
                rowAction("folder", "在访达中显示", delay: 0) {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                rowAction("square.and.arrow.down", "另存为…", delay: 0.03) {
                    exportItem()
                }
                rowAction("xmark", "从抽屉移除", delay: 0.06, tint: DrawerTheme.danger.opacity(0.9), activeTint: DrawerTheme.danger) {
                    removeSelf()
                }
            }
            .opacity(hovered ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, settings.compactRows ? 5.5 : 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(rowFill)
        )
        // 选中指示条：前缘的品牌渐变小胶囊，随选中状态弹性伸缩
        .overlay(alignment: .leading) {
            Capsule()
                .fill(DrawerTheme.accentGradient)
                .frame(width: 3, height: isSelected ? (settings.compactRows ? 16 : 20) : 0)
                .offset(x: 1.5)
                .opacity(isSelected ? 1 : 0)
                .animation(DrawerMotion.snap, value: isSelected)
                .allowsHitTesting(false)
        }
        // 新条目：行底从左到右扫过一道品牌色光后淡出
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: DrawerTheme.accent.opacity(0.26), location: 0),
                            .init(color: DrawerTheme.accentAlt.opacity(0.10), location: 0.6),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .opacity(appearGlow ? 1 : 0)
                .animation(.easeOut(duration: 0.7), value: appearGlow)
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? DrawerTheme.accent.opacity(0.45) : .clear,
                    lineWidth: 1.5
                )
        )
        // 悬停浮起：柔和投影制造"离开列表平面"的层次
        .shadow(
            color: .black.opacity(hovered ? 0.10 : 0),
            radius: hovered ? 8 : 0,
            y: hovered ? 3 : 0
        )
        // 入场：从贴边侧滑入淡入；新拖入的条目交给列表 insertion transition
        .opacity(entered ? 1 : 0)
        .offset(x: entered ? 0 : (settings.edge == .right ? 18 : -18))
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
        .onTapGesture {
            // ⌘/⇧ 点击 = 多选（访达语义）；普通单击在「直接打开」设置下立即打开
            let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if settings.openOnSingleClick, !flags.contains(.command), !flags.contains(.shift) {
                selectRow()
                NSWorkspace.shared.open(item.url)
                return
            }
            DrawerPanel.active?.makeKeyAndOrderFront(nil)
            withAnimation(.easeOut(duration: 0.15)) {
                if flags.contains(.command) {
                    interaction.toggleSelect(item)
                } else if flags.contains(.shift) {
                    interaction.extendSelection(
                        to: item,
                        within: interaction.displayItems(from: store.items)
                    )
                } else {
                    interaction.select(item)
                }
            }
        }
        .contextMenu { rowContextMenu }
        .onDrag {
            let provider = item.dragProvider()
            if settings.collapseAfterDragOut {
                DragSessionObserver.notifyDragEnd {
                    guard settings.collapseAfterDragOut,
                          !InteractionModel.shared.isCollapsed else { return }
                    NotificationCenter.default.post(name: .toggleDrawer, object: nil)
                }
            }
            return provider
        }
        .help(settings.openOnSingleClick
              ? "单击打开 · ⌘点击多选 · 空格预览 · Delete 移除"
              : "单击选中 · ⌘/⇧点击多选 · 双击打开 · 空格预览 · Delete 移除")
        .onAppear {
            store.ensureThumb(for: item)
            if isFreshArrival {
                // 新拖入：立即出现 + 一道品牌色光扫过行底
                entered = true
                appearGlow = true
                Task {
                    try? await Task.sleep(nanoseconds: 550_000_000)
                    appearGlow = false
                }
            } else if staggerEntrance {
                // 首屏/展开：按序错峰滑入
                withAnimation(DrawerMotion.smooth.delay(Double(min(entranceIndex, 10)) * 0.035)) {
                    entered = true
                }
            } else {
                // 入场窗口外重现（搜索过滤回填等）：直接就位
                entered = true
            }
        }
    }

    private var tileSize: CGFloat { settings.compactRows ? 30 : 38 }

    private var metaLine: String { item.metaLine(settings: settings) }

    /// 右键菜单操作目标：行在多选集合里 → 整个集合（访达语义）
    private var menuTargets: [ShelfItem] {
        interaction.selectionTargets(
            containing: item,
            in: interaction.displayItems(from: store.items)
        )
    }

    /// 多选时给菜单项标注数量的后缀
    private func countSuffix(_ targets: [ShelfItem]) -> String {
        targets.count > 1 ? "（\(targets.count) 个）" : ""
    }

    @ViewBuilder
    private var rowContextMenu: some View {
        let targets = menuTargets
        Button("打开\(countSuffix(targets))") {
            for target in targets { NSWorkspace.shared.open(target.url) }
        }
        Button("快速预览") { interaction.togglePreview(for: item) }
        Button("在访达中显示\(countSuffix(targets))") {
            NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url))
        }
        Divider()
        Button(targets.allSatisfy(\.pinned) ? "取消置顶\(countSuffix(targets))" : "置顶\(countSuffix(targets))") {
            store.togglePinned(for: targets)
        }
        Menu("调整顺序") {
            Button("移到最前") { reorderTargets(targets, sendToFront: true) }
            Button("上移") { reorderTargets(targets, nudge: -1) }
            Button("下移") { reorderTargets(targets, nudge: 1) }
            Button("移到最后") { reorderTargets(targets, sendToFront: false) }
        }
        Divider()
        Button("拷贝文件\(countSuffix(targets))") { ClipboardSupport.copyFiles(targets) }
        Button("拷贝路径\(countSuffix(targets))") { copyPaths(targets) }
        Button("移动到文件夹…\(countSuffix(targets))") { moveToFolder(targets) }
        if targets.count == 1 {
            Button("另存为…") { exportItem() }
        }
        Divider()
        Button("移除\(countSuffix(targets))", role: .destructive) {
            removeTargets(targets)
        }
    }

    /// 手动调整顺序：首次使用自动切换到「手动顺序」排序
    private func reorderTargets(_ targets: [ShelfItem], nudge: Int? = nil, sendToFront: Bool? = nil) {
        withAnimation(DrawerMotion.smooth) {
            if interaction.sortMode != .manual { interaction.sortMode = .manual }
            if let nudge {
                store.nudge(ids: targets.map(\.id), by: nudge)
            } else if let sendToFront {
                store.send(ids: targets.map(\.id), toFront: sendToFront)
            }
        }
    }

    /// 单击行：选中 + 把非激活面板设为 key，让键盘导航（空格/↑↓）可用
    private func selectRow() {
        DrawerPanel.active?.makeKeyAndOrderFront(nil)
        withAnimation(.easeOut(duration: 0.15)) {
            interaction.select(item)
        }
    }

    /// 拷贝 POSIX 路径到系统剪贴板（多选时按行拼接）
    private func copyPaths(_ targets: [ShelfItem]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(targets.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// 把一批文件移动到指定文件夹（同名自动追加序号），条目改指新路径
    private func moveToFolder(_ targets: [ShelfItem]) {
        guard !targets.isEmpty else { return }
        let dlg = NSOpenPanel()
        dlg.canChooseFiles = false
        dlg.canChooseDirectories = true
        dlg.canCreateDirectories = true
        dlg.allowsMultipleSelection = false
        dlg.prompt = "移动到这里"
        dlg.message = targets.count == 1
            ? "把「\(item.name)」移动到所选文件夹"
            : "把 \(targets.count) 个条目移动到所选文件夹"
        guard dlg.runModal() == .OK, let folder = dlg.url else { return }

        var moved: [(id: UUID, destination: URL)] = []
        var failures: [Error] = []
        for target in targets {
            let destination = InboxStore.uniqueSiblingURL(fileName: target.name, directory: folder)
            do {
                try FileManager.default.moveItem(at: target.url, to: destination)
                moved.append((target.id, destination))
            } catch {
                failures.append(error)
            }
        }
        guard !moved.isEmpty else {
            if let first = failures.first { NSAlert(error: first).runModal() }
            return
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
            for entry in moved { store.updatePath(id: entry.id, to: entry.destination) }
        }
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = "\(failures.count) 个条目移动失败"
            alert.informativeText = failures.map(\.localizedDescription).joined(separator: "\n")
            alert.runModal()
        }
    }

    private var rowFill: Color {
        if isSelected { return DrawerTheme.accent.opacity(hovered ? 0.13 : 0.09) }
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
                attributed[attr].foregroundColor = DrawerTheme.accent
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
        // 行内 ✕ 与右键菜单同语义：行在多选集合里 → 整批移除（可整批还原）
        removeTargets(interaction.selectionTargets(
            containing: item,
            in: interaction.displayItems(from: store.items)
        ))
    }

    private func removeTargets(_ targets: [ShelfItem]) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
            store.remove(targets)
        }
    }
}

// MARK: - 收起态：贴右缘的窄边条，点击展开；拖文件上去自动展开接收

private struct CollapsedTabView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var interaction: InteractionModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var hovered = false

    private var tabShape: UnevenRoundedRectangle {
        let radius: CGFloat = 17
        return settings.edge == .right
            ? UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: radius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
            : UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: radius,
                topTrailingRadius: radius,
                style: .continuous
            )
    }

    var body: some View {
        ZStack {
            tabShape
                .fill(settings.material.material)
                // 贴边对侧的高光：描边 + 水平渐变（亮在开口侧、向屏幕边缘消失），
                // 描边路径天然跟随圆角，不会像直线那样戳出弧线
                .overlay {
                    tabShape.strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: Color.primary.opacity(hovered ? 0.55 : 0.32), location: 0),
                                .init(color: Color.primary.opacity(hovered ? 0.22 : 0.10), location: 0.10),
                                .init(color: .clear, location: 0.30),
                            ],
                            startPoint: settings.edge == .right ? .leading : .trailing,
                            endPoint: settings.edge == .right ? .trailing : .leading
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
                }
                .overlay {
                    // 拖拽悬停时的接收高亮
                    tabShape
                        .fill(DrawerTheme.accent.opacity(hovered ? 0.10 : 0))
                        .allowsHitTesting(false)
                }

            VStack(spacing: 7) {
                Image(systemName: "tray.full")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(hovered ? AnyShapeStyle(DrawerTheme.accentGradient) : AnyShapeStyle(DrawerTheme.accent))
                    .scaleEffect(hovered ? 1.1 : 1)

                // 悬停时出现一条品牌渐变把手刻度，暗示可以拉开
                Capsule()
                    .fill(DrawerTheme.accentGradient)
                    .frame(width: hovered ? 13 : 7, height: 2)
                    .opacity(hovered ? 1 : 0.4)

                if !store.items.isEmpty {
                    Text("\(store.items.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(.secondary)
                        .animation(DrawerMotion.bouncy, value: store.items.count)
                }
            }
        }
        // 悬停时从屏幕边缘轻轻探出，像被手指勾住往外拉
        .offset(x: hovered ? (settings.edge == .right ? -3 : 3) : 0)
        .scaleEffect(hovered ? 1.03 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(tabShape)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { hovered = hovering }
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
                .foregroundStyle(focused.wrappedValue ? DrawerTheme.accent : .secondary)
                .scaleEffect(focused.wrappedValue ? 1.08 : 1)

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
                .buttonStyle(PressScaleStyle(scale: 0.8))
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
                .fill(Color.primary.opacity(focused.wrappedValue ? 0.07 : 0.05))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            focused.wrappedValue ? DrawerTheme.accent.opacity(0.55) : Color.primary.opacity(0.07),
                            lineWidth: 1
                        )
                )
        )
        // 聚焦时品牌色外发光，视线自然落到输入区
        .shadow(
            color: focused.wrappedValue ? DrawerTheme.accent.opacity(0.28) : .clear,
            radius: 6
        )
        .animation(.easeOut(duration: 0.18), value: focused.wrappedValue)
        .focused(focused)
        .animation(.easeOut(duration: 0.15), value: interaction.searchText.isEmpty)
    }
}

// MARK: - 无结果

private struct NoResultsView: View {
    let query: String
    let clearAction: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(DrawerTheme.accent.opacity(0.55))
                .symbolEffect(.bounce, options: .nonRepeating, value: query)
            Text("没有匹配「\(query)」的条目")
                .font(.system(size: 12, weight: .medium))

            Button(action: clearAction) {
                Text("清除搜索")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4.5)
                    .background(Capsule().fill(DrawerTheme.accent.opacity(0.13)))
                    .foregroundStyle(DrawerTheme.accent)
            }
            .buttonStyle(PressScaleStyle(scale: 0.93))
            .help("清除搜索")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear {
            withAnimation(DrawerMotion.smooth) { appeared = true }
        }
    }
}

// MARK: - 撤销 toast：移除 / 清空后短暂出现，可一键还原

private struct UndoToastView: View {
    let summary: String
    let onUndo: () -> Void
    let onDismiss: () -> Void
    @State private var autoDismissTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "trash")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)

            Text(summary)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)

            Button(action: onUndo) {
                Text("还原")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(DrawerTheme.accentGradient))
            }
            .buttonStyle(PressScaleStyle(scale: 0.92))

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(PressScaleStyle(scale: 0.82))
            .help("关闭")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.8)
                )
        )
        .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
        .onAppear {
            autoDismissTask?.cancel()
            autoDismissTask = Task {
                try? await Task.sleep(nanoseconds: 4_500_000_000)
                guard !Task.isCancelled else { return }
                onDismiss()
            }
        }
        .onDisappear { autoDismissTask?.cancel() }
    }
}

// MARK: - QuickLook 预览弹层

private struct PreviewOverlayView: View {
    let item: ShelfItem
    let store: ShelfStore
    let interaction: InteractionModel

    var body: some View {
        ZStack {
            // 遮罩：毛玻璃把身后的列表推远，点击空白处关闭
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Rectangle().fill(Color.primary.opacity(0.05)))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { interaction.closePreview() }

            card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(
            .asymmetric(
                insertion: .scale(scale: 0.92).combined(with: .opacity),
                removal: .scale(scale: 0.95).combined(with: .opacity)
            )
        )
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
        .shadow(color: .black.opacity(0.32), radius: 28, y: 10)
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
            let t = context.date.timeIntervalSinceReferenceDate
            // 轻微呼吸浮动（3 秒一个周期）
            let drift = isTargeted ? 0 : sin(t / 3 * 2 * .pi) * 3
            // 虚线环缓慢旋转；拖入时加速并反向，像"迎向"文件
            let angle = isTargeted ? -t * 90 : t * 9

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(isTargeted
                              ? AnyShapeStyle(DrawerTheme.accent.opacity(0.08))
                              : AnyShapeStyle(Color.primary.opacity(0.05)))

                    Circle()
                        .strokeBorder(
                            isTargeted ? DrawerTheme.accent.opacity(0.75) : Color.primary.opacity(0.14),
                            style: StrokeStyle(lineWidth: isTargeted ? 1.8 : 1.2, lineCap: .round, dash: [3, 6])
                        )
                        .rotationEffect(.degrees(angle))

                    Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "tray")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(isTargeted ? DrawerTheme.accent : Color.secondary.opacity(0.75))
                }
                .frame(width: 62, height: 62)
                .scaleEffect(isTargeted ? 1.1 : 1)
                .offset(y: drift)

                VStack(spacing: 5) {
                    Text(isTargeted ? "松开，放进抽屉" : "把文件放进来")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isTargeted ? DrawerTheme.accent : Color.primary.opacity(0.85))

                    Text(isTargeted
                         ? "支持一次拖入多个文件"
                         : "从访达拖入文件、文件夹或链接\n也可以直接拖入一段文本 · ⌘V 粘贴")
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
