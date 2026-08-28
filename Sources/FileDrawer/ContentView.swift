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

    /// 当前应展示的条目（当前分组 + 过滤 + 排序后）
    private var displayedItems: [ShelfItem] {
        interaction.displayItems(from: store.currentItems, sort: interaction.sortMode(for: store.currentDrawerID))
    }

    var body: some View {
        Group {
            if interaction.isCollapsed {
                CollapsedTabView(store: store, interaction: interaction, isDropTargeted: $isDropTargeted)
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
        // 切换分组：选中 / 预览随新分组的可见性收回，条目重新错峰入场
        .onChange(of: store.currentDrawerID) {
            interaction.reconcileAfterListChange(with: displayedItems)
            beginEntranceWindow()
        }
    }

    /// VoiceOver 主动播报（toast 是临时视觉元素，屏幕阅读器用户可能错过）
    private func announce(_ text: String) {
        let anchor: Any
        if let window = NSApp.mainWindow ?? NSApp.windows.first {
            anchor = window
        } else if let app = NSApp as NSApplication? {
            anchor = app
        } else {
            return
        }
        NSAccessibility.post(
            element: anchor,
            notification: .announcementRequested,
            userInfo: [NSAccessibility.NotificationUserInfoKey.announcement: text]
        )
    }

    /// 设置开启「清空后自动收起」且当前分组刚被清空时，滑回收起边条
    private func collapseIfEmptyAfterRemoval() {
        guard settings.collapseWhenEmpty,
              store.currentItems.isEmpty,
              !interaction.isCollapsed else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard store.currentItems.isEmpty, !interaction.isCollapsed else { return }
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

                if store.currentItems.isEmpty {
                    // 当前分组为空（含全部分组都空）：展示拖放空态，可直接接收文件
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
            if let notice = store.notice {
                NoticeToastView(text: notice)
                    .id(notice)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(21)
                    .offset(y: store.undoSnapshot == nil ? 0 : 44) // 与撤销 toast 错开
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.undoSnapshot)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.notice)
        // VoiceOver 播报：撤销提示与轻提示出现时朗读文案
        .onChange(of: store.undoSnapshot) { _, snapshot in
            if let summary = snapshot?.summary { announce(summary) }
        }
        .onChange(of: store.notice) { _, text in
            if let text { announce(text) }
        }
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
        .iconHoverState($handleHovered, animation: .spring(response: 0.28, dampingFraction: 0.7))
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .help(L10n.t("收起成边条"))
        .accessibilityLabel(L10n.t("收起成边条"))
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
                LazyVStack(spacing: settings.compactRows ? 5 : 7) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ItemRow(
                            item: item,
                            store: store,
                            interaction: interaction,
                            isSelected: interaction.selectedIDs.contains(item.id),
                            entranceIndex: index,
                            staggerEntrance: entranceWindowActive
                        )
                        // 行级接收器：只认抽屉内部的排序拖拽（自定义类型），
                        // 外部拖入 / 拖出文件的语义不受影响
                        .onDrop(
                            of: [ReorderDrag.type],
                            delegate: RowReorderDropDelegate(
                                rowID: item.id,
                                store: store,
                                interaction: interaction
                            )
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

// MARK: - 行内拖拽排序：行级接收代理

private struct RowReorderDropDelegate: DropDelegate {
    let rowID: UUID
    let store: ShelfStore
    let interaction: InteractionModel

    /// 只接收本应用的排序拖拽。判别依据 = 会话记录（onDrag 开始时同步写入），
    /// 不再检查 / 解码拖拽 provider：真实会话里落点端 provider 由拖拽 pasteboard
    /// 重建，.ownProcess 自定义标记不一定存活（标记丢失 = 行级代理恒拒收 = 拖拽
    /// 排序整个失效），同步 loadDataRepresentation 还会阻塞主线程等异步回调——
    /// validateDrop 每次悬停更新都调用，等于拖动期间持续卡 UI
    func validateDrop(info: DropInfo) -> Bool {
        interaction.reorderDraggedID != nil
    }

    func dropEntered(info: DropInfo) {
        interaction.reorderTargetID = rowID
        updateInsertSlot()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if interaction.reorderTargetID == rowID {
            interaction.reorderTargetID = nil
            interaction.reorderInsertAfter = false
        }
    }

    /// 方向感知落点：源行在目标上方（向下拖）→ 插目标后（指示条画下缘）；
    /// 下方（向上拖）→ 插目标前。固定插前会让「向下拖一格」插回原位 = 无操作。
    private func updateInsertSlot() {
        guard let draggedID = interaction.reorderDraggedID else { return }
        let sort = interaction.sortMode(for: store.currentDrawerID)
        let displayed = interaction.displayItems(from: store.currentItems, sort: sort)
        interaction.reorderInsertAfter =
            InteractionModel.reorderInsertsAfter(draggedID: draggedID, targetID: rowID, in: displayed) ?? false
    }

    func performDrop(info: DropInfo) -> Bool {
        interaction.reorderTargetID = nil
        guard let draggedID = interaction.reorderDraggedID else {
            interaction.reorderInsertAfter = false
            return true
        }
        interaction.reorderLandedOnRow = true
        guard draggedID != rowID else {
            interaction.reorderInsertAfter = false
            return true
        }

        // 拖拽行在多选集合里 → 整批一起移动（访达语义）
        let sort = interaction.sortMode(for: store.currentDrawerID)
        let displayed = interaction.displayItems(from: store.currentItems, sort: sort)
        var movingIDs = [draggedID]
        if interaction.selectedIDs.contains(draggedID), interaction.selectedIDs.count > 1 {
            movingIDs = displayed.filter { interaction.selectedIDs.contains($0.id) }.map(\.id)
        }
        // 落点方位在松手瞬间重估（dropEntered 记录过，这里兜底同一判定）
        let insertAfter = InteractionModel.reorderInsertsAfter(
            draggedID: draggedID, targetID: rowID, in: displayed
        ) ?? interaction.reorderInsertAfter
        interaction.reorderInsertAfter = false

        withAnimation(DrawerMotion.smooth) {
            interaction.switchToManualPreservingDisplay(store: store, drawerID: store.currentDrawerID)
            store.move(ids: movingIDs, before: rowID, after: insertAfter)
        }
        return true
    }
}

// MARK: - 拖放代理（允许多个文件一次性放入；拖到收起态边条上自动展开）

private struct DrawerDropDelegate: DropDelegate {
    let store: ShelfStore
    let interaction: InteractionModel
    @Binding var isTargeted: Bool

    /// 内部排序拖拽落到行外（列表空隙 / 头部）= 取消，不当外部文件「放入」；
    /// 真正的外部文件拖拽照常接收。判别先看会话记录（onDrag 开始时同步写入），
    /// provider 标记只作旁证——真实会话里 .ownProcess 标记不一定存活，
    /// 只靠它会让排序拖拽落到行外时被误收成「放入文件」（条目重复入抽屉）
    func validateDrop(info: DropInfo) -> Bool {
        guard interaction.reorderDraggedID == nil else { return false }
        let files = info.itemProviders(for: DropFileLoader.typeIdentifiers)
        guard !files.isEmpty else { return false }
        return !files.contains { ReorderDrag.isReorderProvider($0) }
    }

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
                let result = store.add(urls: urls)
                if result.skippedDuplicates > 0 {
                    store.postNotice(L10n.tf("已跳过 %d 个重复条目", result.skippedDuplicates))
                }
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
    // 分组管理弹窗
    @State private var newDrawerVisible = false
    @State private var newDrawerName = ""
    @State private var renameDrawerVisible = false
    @State private var renameDrawerName = ""

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

            drawerMenu

            if !store.currentItems.isEmpty {
                Text("\(store.currentItems.count)")
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
                Text(L10n.tf("已选 %d", interaction.selectedIDs.count))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(DrawerTheme.selectionInk)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DrawerTheme.selectionGradient))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }

            Spacer(minLength: 4)

            HStack(spacing: 3) {
                sortMenu
                HoverCircleButton(
                    systemImage: "magnifyingglass",
                    tip: L10n.t("搜索（⌘F）"),
                    size: 25,
                    // 搜索面板打开时常亮品牌色作状态标记；悬停反馈与其他图标一致（中性）
                    tint: interaction.isSearchVisible ? DrawerTheme.accent : .secondary
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        interaction.requestSearchFocus()
                    }
                }
                HoverCircleButton(systemImage: "gearshape", tip: L10n.t("设置（⌘,）"), size: 25) {
                    SettingsWindowManager.shared.show()
                }
                HoverCircleButton(systemImage: "arrow.right.to.line", tip: L10n.t("收起成边条"), size: 25) {
                    NotificationCenter.default.post(name: .toggleDrawer, object: nil)
                }
            }
        }
        .padding(.vertical, 11)
        .animation(DrawerMotion.bouncy, value: store.items.count)
        .animation(DrawerMotion.bouncy, value: interaction.selectedIDs.count)
        .animation(DrawerMotion.bouncy, value: store.currentDrawerID)
    }

    /// 分组切换器：当前分组名 + 下拉菜单（切换 / 新建 / 重命名 / 删除）
    private var drawerMenu: some View {
        Menu {
            ForEach(store.drawers) { group in
                let count = store.itemCount(in: group.id)
                Button {
                    withAnimation(DrawerMotion.smooth) { store.switchDrawer(to: group.id) }
                } label: {
                    if group.id == store.currentDrawerID {
                        Label("\(group.name)（\(count)）", systemImage: "checkmark")
                    } else {
                        Text("\(group.name)（\(count)）")
                    }
                }
            }
            Divider()
            Button(L10n.t("新建分组…")) {
                newDrawerName = ""
                newDrawerVisible = true
            }
            Button(L10n.t("重命名分组…")) {
                renameDrawerName = store.currentDrawerName
                renameDrawerVisible = true
            }
            Button(L10n.t("删除分组"), role: .destructive) {
                // 删除当前分组：条目移到剩余第一个分组（最后一个不可删，按钮已禁用）
                if !store.deleteDrawer(id: store.currentDrawerID) {
                    NSSound.beep()
                }
            }
            .disabled(store.drawers.count <= 1)
        } label: {
            HStack(spacing: 3) {
                Text(store.currentDrawerName)
                    .font(.system(size: 14, weight: .semibold))
                    .kerning(0.2)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.t("切换 / 管理分组"))
        .accessibilityLabel(L10n.t("切换 / 管理分组"))
        .alert(L10n.t("新建分组…"), isPresented: $newDrawerVisible) {
            TextField(L10n.t("分组名"), text: $newDrawerName)
            Button(L10n.t("新建")) {
                if store.createDrawer(named: newDrawerName) == nil { NSSound.beep() }
            }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: {
            Text(L10n.t("新建后自动切换过去；拖入 / 粘贴的文件会放进当前分组。"))
        }
        .alert(L10n.tf("重命名「%@」", store.currentDrawerName), isPresented: $renameDrawerVisible) {
            TextField(L10n.t("分组名"), text: $renameDrawerName)
            Button(L10n.t("重命名")) {
                store.renameDrawer(id: store.currentDrawerID, to: renameDrawerName)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(L10n.t("与其他分组重名会被忽略。"))
        }
    }

    /// 排序菜单：设置的是当前分组的独立排序（各组互不影响）
    private var sortMenu: some View {
        let currentSort = interaction.sortMode(for: store.currentDrawerID)
        return Menu {
            ForEach(InteractionModel.SortMode.allCases) { mode in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        interaction.setSortMode(mode, for: store.currentDrawerID)
                    }
                    // 菜单跟踪期间 onHover 不派发，选中后显式熄灭，避免圆底卡亮
                    withAnimation(DrawerMotion.iconHover) { sortHovered = false }
                } label: {
                    if currentSort == mode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
        } label: {
            // 与 HoverCircleButton 同一套视觉语言：中性圆底 + 图标轻放大
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 25 * 0.46, weight: .medium))
                .foregroundStyle(sortHovered ? Color.primary : Color.secondary)
                .scaleEffect(sortHovered ? 1.1 : 1)
                .frame(width: 25, height: 25)
                .background(
                    Circle().fill(Color.primary.opacity(sortHovered ? 0.09 : 0))
                )
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .iconHoverState($sortHovered)
        .help(L10n.t("排序（仅当前分组）"))
        .accessibilityLabel(L10n.t("排序（仅当前分组）"))
    }
}

/// 悬停时点亮圆形底 + 切换手型光标 + 按压缩放的图标按钮
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
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false
    /// 手动双击判定：上次无修饰键单击的时刻；间隔内二击同一行 = 打开
    @State private var lastRowClickAt: Date?
    /// 首屏错峰入场（从贴边侧滑入淡入）
    @State private var entered = false
    /// 刚拖入的新条目：行底扫过一道品牌色光
    @State private var appearGlow = false
    /// 重命名弹窗
    @State private var renameVisible = false
    @State private var renameText = ""

    /// 是否为"刚刚加入"的条目（区分首屏恢复与新拖入，两者动效不同）
    private var isFreshArrival: Bool {
        Date().timeIntervalSince(item.addedAt) < 1.2
    }

    var body: some View {
        HStack(spacing: settings.compactRows ? 9 : 12) {
            tileWithOverlays

            VStack(alignment: .leading, spacing: settings.compactRows ? 2 : 3.5) {
                nameRow
                metaRow
            }

            Spacer(minLength: 4)

            HStack(spacing: 1) {
                rowAction("folder", L10n.t("在访达中显示"), delay: 0) {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                rowAction("square.and.arrow.down", L10n.t("另存为…"), delay: 0.03) {
                    exportItem()
                }
                rowAction("xmark", L10n.t("移除"), delay: 0.06, tint: DrawerTheme.danger.opacity(0.9), activeTint: DrawerTheme.danger) {
                    removeSelf()
                }
            }
            .opacity(hovered ? 1 : 0)
            .accessibilityHidden(!hovered) // 不可见时不可聚焦；等价操作经右键菜单/键盘可达
        }
        .padding(.horizontal, 12)
        .padding(.vertical, settings.compactRows ? 6 : 10.5)
        .background(
            RoundedRectangle(cornerRadius: rowRadius, style: .continuous)
                .fill(rowFill)
        )
        // 行卡片顶缘高光：与瓷片同一道玻璃语言，让行读作"浮在毛玻璃上的小卡"
        .overlay(
            RoundedRectangle(cornerRadius: rowRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(colorScheme == .dark ? 0.13 : 0.32), location: 0),
                            .init(color: Color.white.opacity(0.03), location: 0.55),
                            .init(color: Color.white.opacity(0), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .allowsHitTesting(false)
        )
        // 行内排序插入指示条：拖拽悬停到本行上时亮起。方位随拖拽方向——
        // 向下拖插到本行后（画下缘），向上拖插到本行前（画上缘），
        // 指示条即最终落点，不会出现「亮在上缘、落点却在下方一格」的误导
        .overlay(alignment: interaction.reorderInsertAfter ? .bottom : .top) {
            if interaction.reorderTargetID == item.id {
                Capsule()
                    .fill(DrawerTheme.accentGradient)
                    .frame(height: 2.5)
                    .padding(.horizontal, 8)
                    .shadow(color: DrawerTheme.accent.opacity(0.5), radius: 3)
                    .allowsHitTesting(false)
            }
        }
        // 悬停出现的排序把手：拖它调整顺序（拖出抽屉外仍是拷贝文件）。
        // 毛玻璃小芯片 + 微投影保证在任何缩略图/瓷片上都有对比度——
        // 裸图标贴着放大后的瓷片落影会被"吃掉"（实测被误读为遮挡）
        .overlay(alignment: .leading) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: settings.compactRows ? 30 : 38)
                .background(
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule(style: .continuous).strokeBorder(
                                LinearGradient(
                                    stops: [
                                        .init(color: Color.white.opacity(colorScheme == .dark ? 0.22 : 0.55), location: 0),
                                        .init(color: Color.white.opacity(0.06), location: 1),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                lineWidth: 0.8
                            )
                        )
                        .shadow(color: .black.opacity(0.14), radius: 2.5, y: 1)
                )
                .contentShape(Rectangle())
                .opacity(hovered ? 1 : 0)
                .scaleEffect(hovered ? 1 : 0.55)
                .allowsHitTesting(hovered)
                .animation(DrawerMotion.iconHover, value: hovered)
                .onDrag {
                    let provider = item.dragProvider()
                    interaction.beginReorderSession(dragging: item.id)
                    ReorderDrag.register(provider, id: item.id)
                    return provider
                }
                .help(L10n.t("拖动调整顺序（自动切入手动顺序；拖出抽屉外 = 拷贝文件）"))
                .padding(.leading, 2.5)
        }
        // 新条目：行底从左到右扫过一道品牌色光后淡出
        .overlay(
            RoundedRectangle(cornerRadius: rowRadius, style: .continuous)
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
            RoundedRectangle(cornerRadius: rowRadius, style: .continuous)
                .strokeBorder(
                    isSelected ? DrawerTheme.selection.opacity(0.32) : .clear,
                    lineWidth: 1
                )
        )
        // 悬停浮起：柔和投影制造"离开列表平面"的层次；紧凑行卡片更小，投影同步收敛
        .shadow(
            color: .black.opacity(hovered ? 0.10 : 0),
            radius: hovered ? (settings.compactRows ? 6.5 : 8) : 0,
            y: hovered ? (settings.compactRows ? 2.5 : 3) : 0
        )
        // 入场：从贴边侧滑入淡入；新拖入的条目交给列表 insertion transition
        .opacity(entered ? (isMissing ? 0.55 : 1) : 0)
        .offset(x: entered ? 0 : (settings.edge == .right ? 18 : -18))
        .animation(.easeOut(duration: 0.3), value: isMissing)
        .contentShape(RoundedRectangle(cornerRadius: rowRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint(settings.openOnSingleClick ? L10n.t("双击打开文件") : L10n.t("单击选中，双击打开文件"))
        .accessibilityAddTraits(.isButton)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                hovered = hovering
            }
        }
        // 手动双击判定（单击立即高亮）：不用 onTapGesture(count:2)+单击 叠加——
        // 那套叠加里单击要等系统双击窗口超时（≈0.5s，随用户设置可到 1s）才确认触发，
        // 选中高亮体感「点了一秒才亮」。改为单击先选中，间隔内再点同一行 = 打开。
        .onTapGesture {
            // ⌘/⇧ 点击 = 多选（访达语义）；普通单击在「直接打开」设置下立即打开
            let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if settings.openOnSingleClick, !flags.contains(.command), !flags.contains(.shift) {
                selectRow()
                openItem()
                return
            }
            // 双击打开：修饰键多选点击不参与判定，避免 ⌘/⇧ 快速连点误触发打开
            let isMultiselectClick = flags.contains(.command) || flags.contains(.shift)
            if !isMultiselectClick,
               let last = lastRowClickAt,
               Date().timeIntervalSince(last) < NSEvent.doubleClickInterval {
                lastRowClickAt = nil
                openItem()
                return
            }
            if !isMultiselectClick { lastRowClickAt = Date() }
            DrawerPanel.active?.makeKeyAndOrderFront(nil)
            withAnimation(.easeOut(duration: 0.15)) {
                if flags.contains(.command) {
                    interaction.toggleSelect(item)
                } else if flags.contains(.shift) {
                    interaction.extendSelection(
                        to: item,
                        within: interaction.displayItems(from: store.currentItems, sort: interaction.sortMode(for: store.currentDrawerID))
                    )
                } else {
                    interaction.select(item)
                }
            }
        }
        .contextMenu { rowContextMenu }
        .onDrag {
            let provider = item.dragProvider()
            // 行体拖拽与把手拖拽开同一种排序会话：悬停其他行即出现排序指示、
            // 松手排序；拖到抽屉外仍是文件拷贝（外部目标端忽略自定义类型）。
            // 两处都开是刻意的：SwiftUI 嵌套 onDrag 的命中归属不可靠，
            // 无论哪处闭包被触发都能开出可排序的会话
            interaction.beginReorderSession(dragging: item.id)
            ReorderDrag.register(provider, id: item.id)
            if settings.collapseAfterDragOut {
                DragSessionObserver.notifyDragEnd {
                    guard settings.collapseAfterDragOut,
                          !InteractionModel.shared.isCollapsed,
                          // 松手落在行上 = 排序，不是拖出 → 不收起
                          !InteractionModel.shared.reorderLandedOnRow else { return }
                    NotificationCenter.default.post(name: .toggleDrawer, object: nil)
                }
            }
            return provider
        }
        .help(settings.openOnSingleClick
              ? L10n.t("单击打开 · ⌘点击多选 · 空格预览 · Delete 移除")
              : L10n.t("单击选中 · ⌘/⇧点击多选 · 双击打开 · 空格预览 · Delete 移除"))
        .alert(L10n.tf("重命名「%@」", item.name), isPresented: $renameVisible) {
            TextField(L10n.t("新名称"), text: $renameText)
            Button(L10n.t("重命名")) {
                if !store.rename(id: item.id, to: renameText) {
                    NSSound.beep()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(L10n.t("将同时修改磁盘上的文件；同名文件会自动追加序号。"))
        }
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

    private var tileSize: CGFloat { settings.compactRows ? 32 : 42 }

    /// 名称字号：紧凑档随瓷片收敛一档（13→12.5），文字栏不再与 32pt 瓷片等高争位，
    /// 让瓷片重新成为行的视觉主导；标准档维持 13（469e63a 定稿的可读性）
    private var nameFontSize: CGFloat { settings.compactRows ? 12.5 : 13 }

    /// 行卡片圆角：随密度模式缩放，与更宽敞的行内边距配套
    private var rowRadius: CGFloat { settings.compactRows ? 11 : 13 }

    /// 瓷片 + 置顶角标 + 多选拖拽把手层
    private var tileWithOverlays: some View {
        FileTile(item: item, thumbs: store.thumbs, size: tileSize)
            .overlay(alignment: .topLeading) {
                if item.pinned {
                    // 置顶角标：品牌色小图钉，压在瓷片左上角。
                    // 三项尺寸随瓷片等比（42pt 为基准），32pt 紧凑瓷片上不再盖住近半张缩略图
                    let k = tileSize / 42
                    Image(systemName: "pin.fill")
                        .font(.system(size: 7 * k, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3 * k)
                        .background(Circle().fill(DrawerTheme.accentGradient))
                        .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 0.6))
                        .offset(x: -3 * k, y: -3 * k)
                        .help(L10n.t("已置顶 · 免于自动清理"))
                }
            }
            // 多选时瓷片变成整批拖拽把手：拖它 = 拖出全部选中条目
            .overlay {
                MultiDragOverlay(
                    active: !batchDragTargets.isEmpty,
                    targets: batchDragTargets,
                    onSessionBegan: {
                        guard settings.collapseAfterDragOut else { return }
                        DragSessionObserver.notifyDragEnd {
                            guard settings.collapseAfterDragOut,
                                  !InteractionModel.shared.isCollapsed else { return }
                            NotificationCenter.default.post(name: .toggleDrawer, object: nil)
                        }
                    }
                )
            }
            .help(batchDragTargets.isEmpty ? "" : L10n.tf("拖动瓷片可拖出整批（%d 个）", batchDragTargets.count))
            .scaleEffect(hovered ? 1.07 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: hovered)
    }

    private var metaLine: String { item.metaLine(settings: settings) }

    /// 文件已不在磁盘上（后台扫描结果）
    private var isMissing: Bool { store.missingIDs.contains(item.id) }

    /// 元信息行文案：失效 / 内容命中时加前缀标注
    private var displayMeta: String {
        var parts: [String] = []
        if isContentMatch { parts.append(L10n.t("内容匹配")) }
        if isMissing { parts.append(L10n.t("文件已不存在")) }
        if !metaLine.isEmpty { parts.append(metaLine) }
        return parts.joined(separator: " · ")
    }

    /// 无障碍描述：名称 + （置顶 / 失效）+ 元信息
    private var accessibilityDescription: String {
        var parts = [item.name]
        if item.pinned { parts.append(L10n.t("已置顶")) }
        if isMissing { parts.append("文件已不存在") }
        if !displayMeta.isEmpty { parts.append(displayMeta) }
        return parts.joined(separator: "，")
    }

    /// 名称行：搜索命中高亮 + 失效警示角标
    private var nameRow: some View {
        HStack(spacing: 4) {
            highlightName
            if isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DrawerTheme.danger)
                    .help(L10n.t("文件已不存在"))
            }
        }
    }

    /// 名称未命中但内容命中（Spotlight）的条目：在名称旁加个小标注
    private var isContentMatch: Bool {
        guard interaction.contentMatchIDs.contains(item.id) else { return false }
        let keywords = InteractionModel.parseQuery(interaction.searchText).keywords
        return !keywords.isEmpty && !keywords.allSatisfy { item.name.localizedStandardContains($0) }
    }

    /// 元信息行：大小 · 时间；失效时红色提示；内容命中时标注来源
    @ViewBuilder
    private var metaRow: some View {
        if isMissing || !metaLine.isEmpty || isContentMatch {
            Text(displayMeta)
                .font(.system(size: settings.compactRows ? 10 : 11.5))
                .foregroundStyle(isMissing
                                 ? AnyShapeStyle(DrawerTheme.danger.opacity(0.8))
                                 : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// 打开守卫：失效条目不给系统投递 open（避免无声失败），提示音代替
    private func openItem() {
        if isMissing {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(item.url)
    }

    /// 多选批量拖出的目标集合：行在多选集合里才非空（此时瓷片是拖拽把手）
    private var batchDragTargets: [ShelfItem] {
        guard interaction.selectedIDs.contains(item.id),
              interaction.selectedIDs.count > 1 else { return [] }
        return interaction.selectedItems(
            in: interaction.displayItems(
                from: store.currentItems,
                sort: interaction.sortMode(for: store.currentDrawerID)
            )
        )
    }

    /// 右键菜单操作目标：行在多选集合里 → 整个集合（访达语义）；范围限当前分组
    private var menuTargets: [ShelfItem] {
        interaction.selectionTargets(
            containing: item,
            in: interaction.displayItems(from: store.currentItems, sort: interaction.sortMode(for: store.currentDrawerID))
        )
    }

    /// 多选时给菜单项标注数量的后缀
    private func countSuffix(_ targets: [ShelfItem]) -> String {
        targets.count > 1 ? L10n.tf("（%d 个）", targets.count) : ""
    }

    @ViewBuilder
    private var rowContextMenu: some View {
        let targets = menuTargets
        Button(L10n.t("打开") + countSuffix(targets)) {
            let openable = targets.filter { !store.missingIDs.contains($0.id) }
            if openable.count < targets.count { NSSound.beep() }
            for target in openable { NSWorkspace.shared.open(target.url) }
        }
        if !isMissing, targets.count == 1 {
            openWithMenu
        }
        Button(L10n.t("快速预览")) { interaction.togglePreview(for: item) }
        Button(L10n.t("在访达中显示") + countSuffix(targets)) {
            NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url))
        }
        Divider()
        Button(targets.allSatisfy(\.pinned) ? L10n.t("取消置顶") + countSuffix(targets) : L10n.t("置顶") + countSuffix(targets)) {
            store.togglePinned(for: targets)
        }
        Menu(L10n.t("调整顺序")) {
            Button(L10n.t("移到最前")) { reorderTargets(targets, sendToFront: true) }
            Button(L10n.t("上移")) { reorderTargets(targets, nudge: -1) }
            Button(L10n.t("下移")) { reorderTargets(targets, nudge: 1) }
            Button(L10n.t("移到最后")) { reorderTargets(targets, sendToFront: false) }
        }
        if store.drawers.count > 1 {
            Menu(L10n.t("移动到分组") + countSuffix(targets)) {
                ForEach(store.drawers.filter { $0.id != store.currentDrawerID }) { group in
                    Button("\(group.name)（\(store.itemCount(in: group.id))）") {
                        store.moveItems(ids: targets.map(\.id), to: group.id)
                    }
                }
            }
        }
        Divider()
        Button(L10n.t("拷贝文件") + countSuffix(targets)) { ClipboardSupport.copyFiles(targets) }
        Button(L10n.t("拷贝路径") + countSuffix(targets)) { copyPaths(targets) }
        Button(L10n.t("移动到文件夹…") + countSuffix(targets)) { moveToFolder(targets) }
        if targets.count == 1 {
            Button(L10n.t("重命名…")) {
                renameText = item.name
                renameVisible = true
            }
            Button(L10n.t("另存为…")) { exportItem() }
        }
        Divider()
        Button(L10n.t("移除") + countSuffix(targets), role: .destructive) {
            removeTargets(targets)
        }
    }

    /// 手动调整顺序：首次使用自动切换到「手动顺序」排序（冻结屏幕所见为基准）
    private func reorderTargets(_ targets: [ShelfItem], nudge: Int? = nil, sendToFront: Bool? = nil) {
        withAnimation(DrawerMotion.smooth) {
            interaction.switchToManualPreservingDisplay(store: store, drawerID: store.currentDrawerID)
            if let nudge {
                store.nudge(ids: targets.map(\.id), by: nudge)
            } else if let sendToFront {
                store.send(ids: targets.map(\.id), toFront: sendToFront)
            }
        }
    }

    /// 打开方式子菜单：默认应用排最前，点击用所选应用打开
    @ViewBuilder
    private var openWithMenu: some View {
        let apps = OpenWithCatalog.apps(for: item.url)
        Menu(L10n.t("打开方式")) {
            ForEach(apps, id: \.url.absoluteString) { app in
                Button(app.name) {
                    OpenWithCatalog.open(item.url, withApplicationAt: app.url)
                }
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
        dlg.prompt = L10n.t("移动到这里")
        dlg.message = targets.count == 1
            ? L10n.tf("把「%@」移动到所选文件夹", item.name)
            : L10n.tf("把 %d 个条目移动到所选文件夹", targets.count)
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
            alert.messageText = L10n.tf("%d 个条目移动失败", failures.count)
            alert.informativeText = failures.map(\.localizedDescription).joined(separator: "\n")
            alert.runModal()
        }
    }

    /// 行底：选中 = 青釉罩染（前浓后淡的一层薄釉 + 发丝描边勾勒卡片轮廓，
    /// 不另加指示条）；平时 = 中性微浮层。两侧都是同构渐变，切换可平滑插值。
    private var rowFill: LinearGradient {
        if isSelected {
            return LinearGradient(
                stops: [
                    .init(color: DrawerTheme.selection.opacity(hovered ? 0.20 : 0.15), location: 0),
                    .init(color: DrawerTheme.selection.opacity(hovered ? 0.13 : 0.10), location: 0.45),
                    .init(color: DrawerTheme.selection.opacity(hovered ? 0.07 : 0.05), location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
        }
        let tint = Color.primary.opacity(hovered ? 0.08 : 0.05)
        return LinearGradient(
            stops: [
                .init(color: tint, location: 0),
                .init(color: tint, location: 0.45),
                .init(color: tint, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    /// 搜索命中时高亮名称中的匹配片段（kind: 语法只高亮名称关键字部分）
    @ViewBuilder
    private var highlightName: some View {
        let keywords = InteractionModel.parseQuery(interaction.searchText)
            .keywords
            .filter { !$0.isEmpty && item.name.localizedStandardContains($0) }

        if keywords.isEmpty {
            Text(item.name)
                .font(.system(size: nameFontSize, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text(SearchNameHighlight.attributed(item.name, keywords: keywords, fontSize: nameFontSize))
                .font(.system(size: nameFontSize, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
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
        dlg.prompt = L10n.t("导出")
        if dlg.runModal() == .OK, let dest = dlg.url {
            try? FileManager.default.copyItem(at: item.url, to: dest)
        }
    }

    private func removeSelf() {
        // 行内 ✕ 与右键菜单同语义：行在多选集合里 → 整批移除（可整批还原）
        removeTargets(interaction.selectionTargets(
            containing: item,
            in: interaction.displayItems(from: store.currentItems, sort: interaction.sortMode(for: store.currentDrawerID))
        ))
    }

    private func removeTargets(_ targets: [ShelfItem]) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
            store.remove(targets)
        }
    }
}

// MARK: - 收起态：贴屏幕边缘的窄边条，点击展开；拖文件上去自动展开接收
// 设计：上段「纸叠」透出最近几条的缩略瓷片（像从抽屉缝里露出的纸堆），
// 中段把手（品牌色胶囊 + 指向屏幕中线的 chevron，指示拉开方向），
// 下段品牌色计数徽章；空态换成虚线纸槽。

private struct CollapsedTabView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var interaction: InteractionModel
    /// 外部文件拖到边条上时的高亮（自动展开关闭时也要有可见反馈）
    @Binding var isDropTargeted: Bool
    @ObservedObject private var settings = AppSettings.shared
    @State private var hovered = false

    private static let peekLimit = 3
    private static let tileSize: CGFloat = 24

    /// 纸叠内容：与展开后看到的顺序一致的前几条
    private var peekItems: [ShelfItem] {
        Array(interaction.displayItems(
            from: store.currentItems,
            sort: interaction.sortMode(for: store.currentDrawerID)
        ).prefix(Self.peekLimit))
    }

    private var peekItemIDs: [UUID] { peekItems.map(\.id) }

    private var tabShape: UnevenRoundedRectangle {
        let radius: CGFloat = 18
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
                    // 拖拽悬停的接收罩染（鼠标悬停不罩染，保持材质干净）
                    tabShape
                        .fill(DrawerTheme.accent.opacity(isDropTargeted ? 0.14 : 0))
                        .allowsHitTesting(false)
                }
                .overlay {
                    // 拖拽悬停：实线接收描边
                    if isDropTargeted {
                        tabShape.strokeBorder(DrawerTheme.accent.opacity(0.7), lineWidth: 1.5)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    // 鼠标悬停：品牌描边浮现，与点亮的把手相呼应
                    tabShape.strokeBorder(DrawerTheme.accent.opacity(hovered ? 0.45 : 0), lineWidth: 1)
                        .allowsHitTesting(false)
                }

            VStack(spacing: 9) {
                if peekItems.isEmpty {
                    emptySlot
                } else {
                    peekStack
                }
                pullHandle
                if !store.currentItems.isEmpty {
                    countBadge
                }
            }
        }
        // 悬停 = 从玻璃上揭起：外探行程加大 + 朝开口侧的接触投影；
        // 不做整体缩放——细长边条一缩放就晃
        .shadow(
            color: .black.opacity(hovered ? 0.16 : 0),
            radius: hovered ? 9 : 0,
            x: hovered ? (settings.edge == .right ? -3 : 3) : 0,
            y: 2
        )
        .offset(x: hovered ? (settings.edge == .right ? -5 : 5) : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(tabShape)
        .iconHoverState($hovered, animation: .spring(response: 0.35, dampingFraction: 0.6))
        // 手型光标持续保障：面板为 key 窗口时，AppKit 会在每次 mouseMoved 按窗口
        // cursor rect 把光标重置回箭头，onHover 只在进出时设置一次会被冲掉——
        // 连续悬停在每次移动时重新按下手型，离开（.ended）时复原箭头
        .onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.arrow.set()
            @unknown default: break
            }
        }
        .onTapGesture {
            DrawerPanel.active?.makeKeyAndOrderFront(nil)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
                interaction.isCollapsed = false
            }
        }
        .onAppear { loadPeekThumbs() }
        .onChange(of: peekItemIDs) { loadPeekThumbs() }
        .help(L10n.t("展开抽屉"))
        .accessibilityLabel(L10n.t("展开抽屉"))
        .accessibilityAddTraits(.isButton)
    }

    /// 纸叠：顶层是最新条目的内容瓷片；下两层是不透明的「纸卡」——
    /// 实底 + 细描边、同尺寸不缩小，只露出上缘，像真实纸叠的纸边
    /// （半透明缩小层在小尺寸下只会糊成一片灰影）。
    /// 悬停时纸叠被「捏开」：层间距撑大、顶层多抬一点，纸堆张开成扇。
    private var peekStack: some View {
        ZStack {
            // 深层先画，顶层后画盖在上面
            ForEach(Array(peekItems.enumerated().reversed()), id: \.element.id) { index, item in
                let depth = CGFloat(index)
                let spread: CGFloat = hovered ? 8 : 5
                let hoverLift: CGFloat = hovered && index == 0 ? 2 : 0
                Group {
                    if index == 0 {
                        FileTile(item: item, thumbs: store.thumbs, size: Self.tileSize)
                    } else {
                        paperCard
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: Self.tileSize * 0.27, style: .continuous)
                        .strokeBorder(Color.primary.opacity(hovered ? 0.24 : 0.16), lineWidth: 0.6)
                )
                .offset(y: -depth * spread - hoverLift)
                .shadow(
                    color: .black.opacity(index == 0 ? (hovered ? 0.26 : 0.20) : 0.10),
                    radius: hovered ? 3.5 : 2.5, y: 1.5
                )
            }
        }
    }

    /// 纸卡：不透明的「一张纸」，只在层间露出边缘。
    /// 必须定死尺寸：fill 形状会吞掉提议尺寸（整个边条宽 × 剩余高），把 VStack 撑散。
    private var paperCard: some View {
        RoundedRectangle(cornerRadius: Self.tileSize * 0.27, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .frame(width: Self.tileSize, height: Self.tileSize)
    }

    /// 把手：胶囊槽 + 指向屏幕中线的 chevron，悬停时外探并亮起胶囊底板，暗示「往中间拉开」
    private var pullHandle: some View {
        VStack(spacing: 3) {
            Capsule()
                .fill(DrawerTheme.accentGradient)
                .frame(width: hovered ? 14 : 10, height: 2.5)
                .opacity(hovered ? 1 : 0.7)
            Image(systemName: settings.edge == .right ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(DrawerTheme.accent.opacity(hovered ? 1 : 0.65))
                .offset(x: hovered ? (settings.edge == .right ? -2.5 : 2.5) : 0)
        }
        .padding(.vertical, 5)
        .background(
            // 悬停时亮起的拉手底板，与展开态抽屉拉手同一视觉语言
            Capsule().fill(Color.primary.opacity(hovered ? 0.09 : 0))
        )
    }

    /// 计数徽章：品牌渐变胶囊，与撤销 toast 的按钮同一视觉语言
    private var countBadge: some View {
        Text("\(store.currentItems.count)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5.5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(DrawerTheme.accentGradient))
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            .contentTransition(.numericText())
            .animation(DrawerMotion.bouncy, value: store.currentItems.count)
    }

    /// 空态：虚线纸槽 + 一抹浅浅的托盘图标
    private var emptySlot: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(width: 26, height: 26)
            .overlay {
                Image(systemName: "tray")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
    }

    /// 收起态也会透出缩略图：补齐纸叠条目的解码（未展开时 FileTile 行不会触发）
    private func loadPeekThumbs() {
        for item in peekItems { store.ensureThumb(for: item) }
    }
}

// MARK: - 搜索栏

/// 搜索命中高亮：给名称里的命中片段上品牌色 + 加粗。
/// run 级属性必须走 AppKit scope（NSColor / NSFont）：SwiftUI scope 的 Color·Font
/// run 属性在实机 Text 渲染路径会被整体丢弃（高亮从未显示过），只有离屏
/// ImageRenderer 渲染得出——排查记录见 DrawerTheme.accentNSColor
enum SearchNameHighlight {
    /// 共享单例：相邻命中段的 run 属性值相等才能合并成一个 run
    private static let accent = DrawerTheme.accentNSColor

    static func attributed(_ text: String, keywords: [String], fontSize: CGFloat) -> AttributedString {
        var attributed = AttributedString(text)
        let lowerText = text.lowercased()
        for keyword in keywords {
            let lowerQuery = keyword.lowercased()
            var searchStart = lowerText.startIndex
            while let range = lowerText.range(of: lowerQuery, range: searchStart..<lowerText.endIndex) {
                if let attr = Range(range, in: attributed) {
                    attributed[attr].appKit.foregroundColor = accent
                    attributed[attr].appKit.font = .boldSystemFont(ofSize: fontSize)
                }
                searchStart = range.upperBound
            }
        }
        return attributed
    }
}

