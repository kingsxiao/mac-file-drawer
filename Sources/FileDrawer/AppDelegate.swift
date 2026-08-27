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

        let displayed = model.displayItems(from: store.items)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+F 聚焦/显示搜索框
        if flags == .command, event.keyCode == 3 { // F
            model.requestSearchFocus()
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
            if model.isSearchVisible, model.searchText.isEmpty {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    model.clearSearchAndHideIfNeeded()
                }
                return nil
            }

        case 125, 126: // Down / Up
            let step = event.keyCode == 125 ? 1 : -1
            model.moveSelection(by: step, within: displayed)
            return nil

        case 36, 76: // Return / Enter：打开选中文件
            if let item = model.selectedItem(in: displayed) {
                NSWorkspace.shared.open(item.url)
                return nil
            }

        case 51: // Delete：移除选中条目
            if let item = model.selectedItem(in: displayed) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    store.remove(item)
                }
                return nil
            }

        default:
            break
        }
        return event
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: DrawerPanel!
    private var contentLayoutGuide = NSLayoutConstraint()
    private var statusItem: NSStatusItem!
    private var isOpen = false
    private let keyboardRouter = KeyboardRouter()
    private let settings = AppSettings.shared
    private var settingsCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = ShelfStore.shared
        let hostingView = NSHostingView(rootView: ContentView(store: store, interaction: .shared))

        let screen = NSScreen.main ?? NSScreen.screens[0]
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
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let target = collapsed
                ? DrawerLayout.collapsedFrame(visibleFrame: screen.visibleFrame, settings: self.settings)
                : DrawerLayout.expandedFrame(visibleFrame: screen.visibleFrame, settings: self.settings)
            self.animateFrame(to: target)
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
            DrawerLayout.offscreenFrame(visibleFrame: (NSScreen.main ?? NSScreen.screens[0]).visibleFrame, settings: settings),
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
            to: DrawerLayout.expandedFrame(visibleFrame: (NSScreen.main ?? NSScreen.screens[0]).visibleFrame, settings: settings)
        )
        refreshStatusTitle()
    }

    func expandDrawer() {
        InteractionModel.shared.isCollapsed = false // 触发边框动画（若处于收起态）
        slideInExpanded()
    }

    func collapseDrawer() {
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

    /// 把当前设置应用到窗口（外观 / 层级 / 热键 / 贴边几何）
    private func applySettings() {
        guard panel != nil else { return }
        panel.appearance = settings.appearance.nsAppearance
        panel.level = settings.panelLevel.nsLevel
        HotKeyCenter.shared.update(settings.hotKeyEnabled ? settings.hotKeyBinding : nil) { [weak self] in
            self?.toggleCollapseOrExpand()
        }
        repositionPanel()
    }

    /// 按当前状态（展开 / 收起 / 屏幕外）立即贴边定位
    private func repositionPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
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
        statusItem?.button?.toolTip = isOpen ? "收起抽屉" : "展开抽屉"
    }

    // MARK: - 菜单栏图标

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "tray.full",
                accessibilityDescription: "文件抽屉"
            )
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "显示 / 隐藏抽屉", action: #selector(toggleAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "导入文件…", action: #selector(importAction), keyEquivalent: "")
        menu.addItem(withTitle: "清空抽屉", action: #selector(clearAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(settingsAction), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出文件抽屉", action: #selector(quitAction), keyEquivalent: "q")
        statusItem.menu = menu
    }

    /// 最小主菜单：让 ⌘,（设置）、⌘H / ⌘Q 等标准快捷键生效
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem(title: "文件抽屉", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "设置…", action: #selector(settingsAction), keyEquivalent: ",")
        appMenu.addItem(.separator())
        // 头部空间有限，导入 / 清空收进菜单（拖拽仍是放入文件的主方式）
        appMenu.addItem(withTitle: "导入文件…", action: #selector(importAction), keyEquivalent: "o")
        appMenu.addItem(withTitle: "清空抽屉", action: #selector(clearAction), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏文件抽屉", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "隐藏其他",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出文件抽屉", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")
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
        dlg.prompt = "放入抽屉"
        dlg.message = "选择要放进抽屉的文件或文件夹"
        if dlg.runModal() == .OK {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                ShelfStore.shared.add(urls: Array(dlg.urls))
            }
        }
    }

    @objc private func clearAction() {
        ShelfStore.shared.clear()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    // 点击 Dock 图标重新弹出抽屉
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        expandDrawer()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ShelfStore.shared.persist()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let collapsed = InteractionModel.shared.isCollapsed
        menu.items.first?.title = collapsed ? "展开抽屉" : (isOpen ? "收起成边条" : "展开抽屉")
    }
}
