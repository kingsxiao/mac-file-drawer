import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// 拉手点击 → 收起/展开抽屉
    static let toggleDrawer = Notification.Name("com.wangxiao.filedrawer.toggleDrawer")
}

/// 抽屉面板：贴屏幕右缘、不抢焦点的浮动窗口。
final class DrawerPanel: NSPanel {
    /// 供行点击后把面板设为 key（键盘导航需要）
    static weak var active: DrawerPanel?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class KeyboardRouter {
    private var monitor: Any?
    private weak var panel: DrawerPanel?
    /// PageUp / PageDown 一次跳过的行数（抽屉同屏量级的经验值）
    static let pageStep = 8
    /// ⌘1…⌘9 对应的数字键虚拟键码（注意 ANSI 布局 5/6 顺序颠倒）
    static let digitKeyCodes: [Int] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    func start(panel: DrawerPanel) {
        self.panel = panel
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    /// 返回 nil 表示已消费该按键，不再继续派发。
    private func handle(_ event: NSEvent) -> NSEvent? {
        let model = InteractionModel.shared
        let store = ShelfStore.shared

        // 面板不是 key 窗口时不拦截；收起成边条时也放行
        guard let panel, panel.isKeyWindow, event.window === panel,
              !InteractionModel.shared.isCollapsed else { return event }
        // 正在往搜索框里打字时完全放行（field editor 在响应链最前）
        if panel.firstResponder is NSTextView { return event }

        // 键盘操作的作用域 = 当前分组的展示条目
        let displayed = model.displayItems(from: store.currentItems, sort: model.sortMode(for: store.currentDrawerID))
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+F 聚焦/显示搜索框
        if flags == .command, event.keyCode == 3 { // F
            model.requestSearchFocus()
            return nil
        }
        // Cmd+C 拷贝选中条目的文件（与访达拷贝同构；多选时全部拷贝）
        if flags == .command, event.keyCode == 8 { // C
            let targets = model.selectedItems(in: displayed)
            guard !targets.isEmpty else { return event }
            ClipboardSupport.copyFiles(targets)
            if targets.count > 1 {
                store.postNotice(L10n.tf("已拷贝 %d 个文件", targets.count))
            }
            return nil
        }
        // Cmd+V 把剪贴板里的文件 / 文本 / 链接放入抽屉
        if flags == .command, event.keyCode == 9 { // V
            pasteFromClipboard(store: store)
            return nil
        }
        // Cmd+A 全选当前展示的条目
        if flags == .command, event.keyCode == 0 { // A
            model.selectAll(in: displayed)
            return nil
        }
        // Cmd+1…⌘9：切换到第 N 个分组（超出分组数放行给系统）
        if flags == .command, let index = Self.digitKeyCodes.firstIndex(of: Int(event.keyCode)) {
            let drawers = store.drawers
            guard index < drawers.count else { return event }
            withAnimation(DrawerMotion.smooth) { store.switchDrawer(to: drawers[index].id) }
            return nil
        }

        // Cmd+↑ / Cmd+↓：手动排序下平移选中条目（自动切入「手动顺序」）
        if flags == .command, event.keyCode == 126 || event.keyCode == 125 {
            let targets = model.selectedItems(in: displayed)
            guard !targets.isEmpty else { return event }
            withAnimation(DrawerMotion.smooth) {
                if model.sortMode(for: store.currentDrawerID) != .manual {
                    model.setSortMode(.manual, for: store.currentDrawerID)
                }
                store.nudge(ids: targets.map(\.id), by: event.keyCode == 126 ? -1 : 1)
            }
            return nil
        }

        switch Int(event.keyCode) {
        case 49: // Space：开/关预览
            if model.isPreviewVisible {
                model.closePreview()
            } else if let item = model.selectedItem(in: displayed) {
                model.togglePreview(for: item)
            } else if let only = displayed.first {
                model.select(only)
                model.togglePreview(for: only)
            }
            return nil

        case 53: // Esc
            if model.isPreviewVisible {
                model.closePreview()
                return nil
            }
            if model.selectedID != nil {
                withAnimation(.easeOut(duration: 0.15)) { model.selectedID = nil }
                return nil
            }
            if model.isSearchVisible {
                // 有文本先清空，再按一次才收起搜索框（与常见搜索交互一致）
                if !model.searchText.isEmpty {
                    withAnimation(.easeOut(duration: 0.15)) { model.searchText = "" }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        model.clearSearchAndHideIfNeeded()
                    }
                }
                return nil
            }

        case 125, 126: // Down / Up
            let step = event.keyCode == 125 ? 1 : -1
            model.moveSelection(by: step, within: displayed)
            return nil

        case 123, 124: // Left / Right：预览打开时同样切换条目（与 ↑↓ 等效）
            if model.isPreviewVisible {
                let step = event.keyCode == 124 ? 1 : -1
                model.moveSelection(by: step, within: displayed)
                return nil
            }

        case 116: // PageUp：上翻一页
            model.moveSelection(by: -Self.pageStep, within: displayed)
            return nil

        case 121: // PageDown：下翻一页
            model.moveSelection(by: Self.pageStep, within: displayed)
            return nil

        case 115: // Home：选中第一条
            if let first = displayed.first {
                withAnimation(DrawerMotion.smooth) { model.select(first) }
            }
            return nil

        case 119: // End：选中最后一条
            if let last = displayed.last {
                withAnimation(DrawerMotion.smooth) { model.select(last) }
            }
            return nil

        case 36, 76: // Return / Enter：打开选中文件（多选时全部打开；失效的跳过并提示）
            let targets = model.selectedItems(in: displayed)
            if !targets.isEmpty {
                let openable = targets.filter { !store.missingIDs.contains($0.id) }
                if openable.count < targets.count { NSSound.beep() }
                for item in openable { NSWorkspace.shared.open(item.url) }
                return nil
            }

        case 51: // Delete：移除选中条目（多选时批量移除，可整批还原）
            let targets = model.selectedItems(in: displayed)
            if !targets.isEmpty {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    store.remove(targets)
                }
                return nil
            }

        default:
            break
        }
        return event
    }

    /// ⌘V：剪贴板里的文件原样入列；文本 / 链接物化成收件箱条目
    private func pasteFromClipboard(store: ShelfStore) {
        let urls = ClipboardSupport.pasteableURLs()
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            let result = store.add(urls: urls)
            if result.skippedDuplicates > 0 {
                store.postNotice(L10n.tf("已跳过 %d 个重复条目", result.skippedDuplicates))
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: DrawerPanel!
    private var statusItem: NSStatusItem!
    private var isOpen = false
    private let keyboardRouter = KeyboardRouter()
    private let settings = AppSettings.shared
    private var settingsCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = ShelfStore.shared
        let hostingView = NSHostingView(rootView: ContentView(store: store, interaction: .shared))

        let screen = DrawerLayout.targetScreen(followMouse: settings.followMouseScreen) ?? NSScreen.screens[0]
        let size = DrawerLayout.expandedSize(visibleFrame: screen.visibleFrame, settings: settings)

        panel = DrawerPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        DrawerPanel.active = panel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.level = settings.panelLevel.nsLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.contentView = hostingView
        panel.appearance = settings.appearance.nsAppearance

        buildMainMenu()
        setupStatusItem()
        keyboardRouter.start(panel: panel)

        // 拉手点击 → 收起/展开切换
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleToggleDrawer),
            name: .toggleDrawer, object: nil
        )
        // 显示器配置变化（拔接显示器/换分辨率）时重新贴边定位
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        // 切换到其他应用时按设置自动收起
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil
        )

        // 收起状态变化 → 窗口边框在「抽屉」与「窄边条」之间动画
        InteractionModel.shared.onCollapseChange = { [weak self] collapsed in
            guard let self, self.panel != nil else { return }
            // 任何路径（边条点击 / 拖放悬停 / 热键）展开都汇到这里：
            // 同步 isOpen，否则后续 targetFrame 会把窗口定位到屏幕外
            if !collapsed { self.isOpen = true }
            let screen = DrawerLayout.targetScreen(followMouse: settings.followMouseScreen) ?? NSScreen.screens[0]
            let target = collapsed
                ? DrawerLayout.collapsedFrame(visibleFrame: screen.visibleFrame, settings: self.settings)
                : DrawerLayout.expandedFrame(visibleFrame: screen.visibleFrame, settings: self.settings)
            self.animateFrame(to: target)
            // 展开时顺带校验一遍条目文件存在性（收起期间文件可能被外部删除）
            if !collapsed { ShelfStore.shared.refreshMissingStatus() }
        }

        // 设置变化 → 外观 / 层级 / 热键 / 边框即时生效
        settingsCancellable = settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applySettings() }

        // 初始停在屏幕外，延迟一点再滑入，制造"抽屉抽出"的感觉。
        placeOffscreen()
        applySettings()
        let startCollapsed = ProcessInfo.processInfo.arguments.contains("-collapsed") || settings.launchCollapsed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            if startCollapsed {
                InteractionModel.shared.isCollapsed = true
                self?.isOpen = false
                self?.panel.orderFront(nil) // 以窄边条形态出现，不抢焦点
                self?.refreshStatusTitle()
            } else {
                self?.slideInExpanded()
            }
        }

        _ = NSApplication.shared.windows // 触发初始化
    }

    // MARK: - 展开 / 收起 / 隐藏

    /// 窗口 frame 动画统一走弹簧物理（带轻微过冲回弹），
    /// 抽屉滑入滑出更有"从屏幕里抽出来"的手感。
    private func animateFrame(to frame: NSRect) {
        WindowSpringAnimator.shared.animate(window: panel, to: frame)
    }

    /// 初始停在屏幕外
    private func placeOffscreen() {
        WindowSpringAnimator.shared.cancel()
        panel.setFrame(
            DrawerLayout.offscreenFrame(visibleFrame: (DrawerLayout.targetScreen(followMouse: settings.followMouseScreen) ?? NSScreen.screens[0]).visibleFrame, settings: settings),
            display: false
        )
        isOpen = false
    }

    /// 从屏幕外滑入展开
    private func slideInExpanded() {
        if !panel.isVisible {
            placeOffscreen()
            panel.makeKeyAndOrderFront(nil)
        }
        isOpen = true
        animateFrame(
            to: DrawerLayout.expandedFrame(visibleFrame: (DrawerLayout.targetScreen(followMouse: settings.followMouseScreen) ?? NSScreen.screens[0]).visibleFrame, settings: settings)
        )
        refreshStatusTitle()
    }

    func expandDrawer() {
        // 冷启动早期（URL Scheme / 快捷指令先于面板构建到达）不操作窗口，只改状态
        guard panel != nil else {
            InteractionModel.shared.isCollapsed = false
            return
        }
        InteractionModel.shared.isCollapsed = false // 触发边框动画（若处于收起态）
        slideInExpanded()
    }

    func collapseDrawer() {
        guard panel != nil else {
            InteractionModel.shared.isCollapsed = true
            return
        }
        let model = InteractionModel.shared
        model.closePreview()
        withAnimation(.easeOut(duration: 0.15)) { model.selectedID = nil }
        model.isCollapsed = true // observer 里驱动边框动画
        isOpen = false
        refreshStatusTitle()
    }

    /// 拉手 / 菜单 / Dock 的切换语义：展开 ↔ 收起
    func toggleCollapseOrExpand() {
        if InteractionModel.shared.isCollapsed {
            expandDrawer()
        } else if isOpen {
            collapseDrawer()
        } else {
            expandDrawer()
        }
    }

    private func toggleDrawer() {
        toggleCollapseOrExpand()
    }

    // MARK: - 设置生效

    /// 把当前设置应用到窗口（外观 / 层级 / 热键 / 贴边几何 / Dock 图标）
    private func applySettings() {
        guard panel != nil else { return }
        // 界面语言变化：重建抽屉视图 / 主菜单 / 菜单栏菜单（设置窗口下次打开自然用新语言）
        if L10n.setLanguage(settings.language.code) {
            rebuildUserInterface()
        }
        panel.appearance = settings.appearance.nsAppearance
        panel.level = settings.panelLevel.nsLevel
        // 只有真的变化才切激活策略：反复 set 同值会闪 Dock 图标
        let policy: NSApplication.ActivationPolicy = settings.showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
        HotKeyCenter.shared.update(settings.hotKeyEnabled ? settings.hotKeyBinding : nil) { [weak self] in
            self?.toggleCollapseOrExpand()
        }
        repositionPanel()
    }

    /// 语言切换后重建界面承载的视图与静态菜单
    private func rebuildUserInterface() {
        let store = ShelfStore.shared
        if let hosting = panel.contentView as? NSHostingView<ContentView> {
            hosting.rootView = ContentView(store: store, interaction: .shared)
        }
        buildMainMenu()
        if let menu = statusItem.menu { populateStatusMenu(menu) }
        SettingsWindowManager.shared.refreshLocalization()
    }

    /// 按当前状态（展开 / 收起 / 屏幕外）立即贴边定位
    private func repositionPanel() {
        guard let screen = DrawerLayout.targetScreen(followMouse: settings.followMouseScreen) ?? NSScreen.screens.first else { return }
        // 直接定位前终止弹簧，避免动画把窗口又拉回旧目标
        WindowSpringAnimator.shared.cancel()
        panel.setFrame(targetFrame(for: screen), display: true)
    }

    private func targetFrame(for screen: NSScreen) -> NSRect {
        let visibleFrame = screen.visibleFrame
        if InteractionModel.shared.isCollapsed {
            return DrawerLayout.collapsedFrame(visibleFrame: visibleFrame, settings: settings)
        } else if isOpen {
            return DrawerLayout.expandedFrame(visibleFrame: visibleFrame, settings: settings)
        } else {
            return DrawerLayout.offscreenFrame(visibleFrame: visibleFrame, settings: settings)
        }
    }

    private func refreshStatusTitle() {
        statusItem?.button?.toolTip = isOpen ? L10n.t("收起抽屉") : L10n.t("展开抽屉")
    }

    // MARK: - 菜单栏图标

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "tray.full",
                accessibilityDescription: L10n.t("文件抽屉")
            )
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        populateStatusMenu(menu)
    }

    /// 填充菜单栏菜单（每次打开时原地重建：切换项文案 + 最近条目列表保持最新）
    private func populateStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: L10n.t("显示 / 隐藏抽屉"), action: #selector(toggleAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.t("导入文件…"), action: #selector(importAction), keyEquivalent: "")
        menu.addItem(withTitle: L10n.t("导出当前分组到文件夹…"), action: #selector(exportAllAction), keyEquivalent: "")
        menu.addItem(withTitle: L10n.t("清空当前分组"), action: #selector(clearAction), keyEquivalent: "")

        // 最近条目：按加入时间倒序取前 6 个，点击直接打开
        let recents = Array(
            ShelfStore.shared.items
                .sorted { $0.addedAt > $1.addedAt }
                .prefix(6)
        )
        if !recents.isEmpty {
            menu.addItem(.separator())
            let header = menu.addItem(withTitle: L10n.t("最近条目"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            for item in recents {
                let menuItem = menu.addItem(
                    withTitle: item.name,
                    action: #selector(openRecentAction(_:)),
                    keyEquivalent: ""
                )
                menuItem.representedObject = item.path
            }
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.t("设置…"), action: #selector(settingsAction), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.t("关于文件抽屉"), action: #selector(aboutAction), keyEquivalent: "")
        menu.addItem(withTitle: L10n.t("退出文件抽屉"), action: #selector(quitAction), keyEquivalent: "q")
    }

    /// 最小主菜单：让 ⌘,（设置）、⌘H / ⌘Q 等标准快捷键生效
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem(title: L10n.t("文件抽屉"), action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.t("关于文件抽屉"), action: #selector(aboutAction), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.t("设置…"), action: #selector(settingsAction), keyEquivalent: ",")
        appMenu.addItem(.separator())
        // 头部空间有限，导入 / 清空收进菜单（拖拽仍是放入文件的主方式）
        appMenu.addItem(withTitle: L10n.t("导入文件…"), action: #selector(importAction), keyEquivalent: "o")
        appMenu.addItem(withTitle: L10n.t("清空当前分组"), action: #selector(clearAction), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.t("隐藏文件抽屉"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: L10n.t("隐藏其他"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.t("退出文件抽屉"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem(title: L10n.t("编辑"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L10n.t("编辑"))
        editMenu.addItem(withTitle: L10n.t("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.t("拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.t("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.t("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func toggleAction() { toggleDrawer() }

    @objc private func handleToggleDrawer() {
        toggleDrawer()
    }

    @objc private func settingsAction() {
        SettingsWindowManager.shared.show()
    }

    /// 关于窗口：版本号优先取应用包，开发裸跑时回退到硬编码基线
    @objc private func aboutAction() {
        NSApp.activate(ignoringOtherApps: true)
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
        let store = ShelfStore.shared
        let stats = L10n.tf("当前 %@ 个条目 · %@ 个分组", store.items.count, store.drawers.count)
        let credits = [
            stats,
            L10n.t("Swift + AppKit + SwiftUI · 无第三方依赖"),
            L10n.t("⌥Space 呼出抽屉 · 右键条目看全部操作"),
            L10n.t("自动化：filedrawer:// URL 与快捷指令（Shortcuts）"),
        ].joined(separator: "\n")
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: L10n.tf("版本 %@（%@）", version, build),
            .version: "",
            .credits: credits,
        ])
    }

    @objc private func appDidResignActive() {
        // 设置窗口在屏时不收起（用户正在调整配置）
        guard settings.autoCollapseOnBlur,
              isOpen, !InteractionModel.shared.isCollapsed,
              !SettingsWindowManager.shared.isVisible else { return }
        collapseDrawer()
    }

    @objc private func screenConfigurationChanged() {
        // 按当前状态（展开 / 收起 / 隐藏）重新贴新屏定位
        repositionPanel()
    }

    @objc private func importAction() {
        expandDrawer()
        let dlg = NSOpenPanel()
        dlg.canChooseFiles = true
        dlg.canChooseDirectories = true
        dlg.allowsMultipleSelection = true
        dlg.prompt = L10n.t("放入抽屉")
        dlg.message = L10n.t("选择要放进抽屉的文件或文件夹")
        if dlg.runModal() == .OK {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                let result = ShelfStore.shared.add(urls: Array(dlg.urls))
                if result.skippedDuplicates > 0 {
                    ShelfStore.shared.postNotice(L10n.tf("已跳过 %d 个重复条目", result.skippedDuplicates))
                }
            }
        }
    }

    @objc private func clearAction() {
        ShelfStore.shared.clear()
    }

    /// 菜单栏「最近条目」点击：直接打开对应文件
    @objc private func openRecentAction(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// 导出全部条目到所选文件夹（拷贝，同名自动序号；失效条目跳过）
    @objc private func exportAllAction() {
        let store = ShelfStore.shared
        guard !store.currentItems.isEmpty else {
            NSSound.beep()
            return
        }
        expandDrawer()
        let dlg = NSOpenPanel()
        dlg.canChooseFiles = false
        dlg.canChooseDirectories = true
        dlg.canCreateDirectories = true
        dlg.allowsMultipleSelection = false
        dlg.prompt = L10n.t("导出到这里")
        dlg.message = L10n.tf("把「%@」分组的 %d 个条目拷贝到所选文件夹", store.currentDrawerName, store.currentItems.count)
        guard dlg.runModal() == .OK, let folder = dlg.url else { return }

        // 大文件拷贝放后台，避免冻结主线程（弹簧动画 / 热键 / 菜单）
        let snapshot = store.currentItems.map(\.path)
        Task.detached(priority: .userInitiated) {
            let result = ShelfStore.exportPaths(snapshot, to: folder)
            await MainActor.run {
                let alert = NSAlert()
                alert.alertStyle = result.failed > 0 ? .warning : .informational
                alert.messageText = L10n.tf("已导出 %d 个条目", result.exported)
                var details = [String]()
                if result.skipped > 0 { details.append(L10n.tf("%d 个失效条目已跳过", result.skipped)) }
                if result.failed > 0 { details.append(L10n.tf("%d 个拷贝失败", result.failed)) }
                alert.informativeText = details.joined(separator: "，")
                alert.runModal()
            }
        }
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    // 点击 Dock 图标重新弹出抽屉
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        expandDrawer()
        return true
    }

    // MARK: - URL Scheme（filedrawer://add?path=… 等，配合脚本 / 终端自动化）

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let action = URLRouter.action(for: url) else { continue }
            perform(action)
        }
    }

    /// URL Scheme 动作统一走 DrawerCommands（与快捷指令 / App Intents 同一条路径）
    private func perform(_ action: URLRouter.Action) {
        switch action {
        case .add(let paths, let group):
            expandDrawer()
            let result = DrawerCommands.add(paths: paths, group: group)
            if result.added == 0, result.invalid == paths.count, !paths.isEmpty {
                ShelfStore.shared.postNotice(L10n.t("路径不存在，未放入抽屉"))
            }

        case .reveal(let path):
            expandDrawer()
            DrawerCommands.reveal(path: path)

        case .pin(let group, let limit):
            _ = DrawerCommands.setPinned(group: group, limit: limit, pinned: true)

        case .unpin(let group, let limit):
            _ = DrawerCommands.setPinned(group: group, limit: limit, pinned: false)

        case .sendToFront(let group, let limit):
            let moved = DrawerCommands.sendToFront(group: group, limit: limit)
            if moved > 0 { expandDrawer() }

        case .move(let group, let to, let limit):
            let moved = DrawerCommands.moveItems(group: group, to: to, limit: limit)
            if moved == 0 {
                ShelfStore.shared.postNotice(L10n.t("没有可移动的条目"))
            } else {
                ShelfStore.shared.postNotice(L10n.tf("已移动 %d 个条目到「%@」", moved, to ?? ""))
            }

        case .rename(let path, let newName):
            if !DrawerCommands.renameItem(path: path, to: newName) {
                ShelfStore.shared.postNotice(L10n.t("重命名失败：条目不存在"))
            }

        case .remove(let group, let limit):
            let removed = DrawerCommands.removeItems(group: group, limit: limit)
            if removed == 0 { ShelfStore.shared.postNotice(L10n.t("没有可移除的条目")) }

        case .clear(let group):
            let cleared = DrawerCommands.clearGroup(group)
            if cleared == 0 { ShelfStore.shared.postNotice(L10n.t("分组为空")) }

        case .toggle:
            DrawerCommands.setExpansion(expand: nil)

        case .expand:
            DrawerCommands.setExpansion(expand: true)

        case .collapse:
            DrawerCommands.setExpansion(expand: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ShelfStore.shared.prepareForTermination()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // 原地重建：切换项文案 + 最近条目保持最新（同一个 NSMenu 实例，避免打断正在打开的菜单）
        populateStatusMenu(menu)
    }
}
