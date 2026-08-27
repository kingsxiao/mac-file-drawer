import AppKit
import ServiceManagement
import SwiftUI

// MARK: - 登录项（SMAppService，macOS 13+）
// 真实状态以系统为准（用户可能直接在系统设置里改），界面只做镜像。

enum LoginItemController {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - 设置窗口管理

@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()

    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    /// 语言切换后重建设置面板内容
    func refreshLocalization() {
        if let window, let hosting = window.contentView as? NSHostingView<SettingsView> {
            hosting.rootView = SettingsView()
        }
    }

    func show() {
        if window == nil {
            // contentRect 与 SettingsView 的固定 frame 对齐，避免HostingView 留死边
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = L10n.t("文件抽屉") + " · " + L10n.t("设置")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 设置界面

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label(L10n.t("通用"), systemImage: "gearshape") }
            AppearanceSettingsTab()
                .tabItem { Label(L10n.t("外观"), systemImage: "paintbrush") }
            BehaviorSettingsTab()
                .tabItem { Label(L10n.t("行为"), systemImage: "wand.and.stars") }
            ShortcutSettingsTab()
                .tabItem { Label(L10n.t("快捷键"), systemImage: "keyboard") }
        }
        .frame(width: 480, height: 440)
    }
}

// MARK: 通用

private struct GeneralSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var interaction = InteractionModel.shared
    @ObservedObject private var store = ShelfStore.shared
    /// 登录项状态镜像：系统设置里也可能被用户直接改动，每次出现时重新读取
    @State private var launchAtLogin = false
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section(L10n.t("启动")) {
                Picker(L10n.t("启动时"), selection: $settings.launchCollapsed) {
                    Text(L10n.t("展开抽屉")).tag(false)
                    Text(L10n.t("收起为边条")).tag(true)
                }
                Toggle(L10n.t("登录 macOS 后自动启动"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle(L10n.t("丢弃已不存在的文件"), isOn: $settings.removeMissingOnLaunch)
                Text(L10n.t("关闭后，指向已删除文件的条目会保留在抽屉里，直到手动移除。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L10n.t("列表")) {
                Picker(L10n.t("默认排序"), selection: $interaction.defaultSortMode) {
                    ForEach(InteractionModel.SortMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text(L10n.t("未单独设置排序的分组（含新建分组）用它；每个分组可点头部排序菜单单独设置，互不影响。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(L10n.t("搜索时也匹配文件内容（Spotlight）"), isOn: $settings.searchFileContents)
                    .help(L10n.t("名称没命中时，用 Spotlight 检索文件内容补充结果；被索引过的文档 / 文本才有效"))
                Toggle(L10n.t("单击直接打开"), isOn: $settings.openOnSingleClick)
                Text(L10n.t("开启后单击条目即打开文件；默认单击选中、双击打开（⌘/⇧点击可多选）。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L10n.t("暂存维护")) {
                Picker(L10n.t("自动清理过期条目"), selection: $settings.autoClean) {
                    ForEach(AutoCleanPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                Picker(L10n.t("容量上限"), selection: $settings.maxItems) {
                    ForEach(MaxItemsPolicy.allCases) { limit in
                        Text(limit.label).tag(limit)
                    }
                }
                Text(L10n.t("超出上限时淘汰最早加入的条目；置顶条目不受过期清理与容量淘汰影响。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent(L10n.t("当前分组条目")) {
                    Text("\(store.currentItems.count) \(L10n.t("个"))\(inventorySuffix)")
                        .foregroundStyle(.secondary)
                }
                Button(store.missingIDs.isEmpty
                       ? L10n.t("立即清理已不存在的条目")
                       : L10n.t("立即清理已不存在的条目") + "（\(store.missingIDs.count)）") {
                    store.removeMissing()
                }
                .disabled(store.missingIDs.isEmpty)
            }
            Section(L10n.t("分组容量上限")) {
                ForEach(store.drawers) { group in
                    Picker(group.name, selection: drawerLimitBinding(group.id)) {
                        Text(L10n.t("跟随默认")).tag(MaxItemsPolicy?.none)
                        ForEach(MaxItemsPolicy.allCases) { limit in
                            Text(limit.label).tag(MaxItemsPolicy?.some(limit))
                        }
                    }
                }
                Text(L10n.t("未单独设置的分组用上面的全局「容量上限」；调整后立即生效，淘汰各组内最早加入的条目（置顶豁免）。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            launchAtLogin = LoginItemController.isEnabled
            loginItemError = nil
        }
    }

    /// 条目统计后缀：置顶 N · 失效 M · 共 K 组（都为零时为空）
    private var inventorySuffix: String {
        let current = store.currentItems
        var parts: [String] = []
        let pinned = current.filter(\.pinned).count
        if pinned > 0 { parts.append(L10n.tf("置顶 %d", pinned)) }
        let missing = current.filter { store.missingIDs.contains($0.id) }.count
        if missing > 0 { parts.append(L10n.tf("失效 %d", missing)) }
        if store.drawers.count > 1 { parts.append(L10n.tf("共 %d 组", store.drawers.count)) }
        return parts.isEmpty ? "" : "（\(parts.joined(separator: " · "))）"
    }

    /// 分组容量选择绑定：nil = 跟随默认
    private func drawerLimitBinding(_ drawerID: UUID) -> Binding<MaxItemsPolicy?> {
        Binding(
            get: { store.limitOverride(for: drawerID) },
            set: { store.setLimitOverride($0, for: drawerID) }
        )
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItemController.setEnabled(on)
            loginItemError = nil
        } catch {
            loginItemError = L10n.tf("未能%@登录启动：%@", on ? L10n.t("开启") : L10n.t("关闭"), error.localizedDescription)
        }
        // 无论成败都以系统当前状态为准
        launchAtLogin = LoginItemController.isEnabled
    }
}

// MARK: 外观

private struct AppearanceSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section(L10n.t("主题")) {
                Picker(L10n.t("界面语言"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(L10n.t(language.label)).tag(language)
                    }
                }
                Picker(L10n.t("外观"), selection: $settings.appearance) {
                    ForEach(DrawerAppearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section(L10n.t("抽屉尺寸")) {
                LabeledContent(L10n.t("宽度")) {
                    HStack(spacing: 8) {
                        Slider(value: $settings.drawerWidth, in: DrawerLayout.minWidth...DrawerLayout.maxWidth, step: 5)
                        Text("\(Int(settings.drawerWidth)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent(L10n.t("占屏高度")) {
                    HStack(spacing: 8) {
                        Slider(value: $settings.drawerHeightRatio, in: DrawerLayout.minRatio...DrawerLayout.maxRatio)
                        Text("\(Int(settings.drawerHeightRatio * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker(L10n.t("垂直位置"), selection: $settings.verticalAlignment) {
                    ForEach(DrawerVerticalAlignment.allCases) { alignment in
                        Text(alignment.label).tag(alignment)
                    }
                }
                Picker(L10n.t("停靠边缘"), selection: $settings.edge) {
                    ForEach(DrawerEdge.allCases) { edge in
                        Text(edge.label).tag(edge)
                    }
                }
                Toggle(L10n.t("展开时停靠到鼠标所在屏幕"), isOn: $settings.followMouseScreen)
                    .help(L10n.t("多显示器：在哪块屏展开就贴哪块屏；关闭则始终主屏幕"))
            }
            Section(L10n.t("材质与列表")) {
                Picker(L10n.t("毛玻璃浓度"), selection: $settings.material) {
                    ForEach(DrawerMaterial.allCases) { material in
                        Text(material.label).tag(material)
                    }
                }
                Toggle(L10n.t("紧凑列表"), isOn: $settings.compactRows)
                    .help(L10n.t("更小的瓷片与行距，同屏容纳更多条目"))
                Toggle(L10n.t("显示文件大小"), isOn: $settings.showFileSize)
                Toggle(L10n.t("显示加入时间"), isOn: $settings.showAddedTime)
                Toggle(L10n.t("显示缩略图（图片 / 视频 / PDF）"), isOn: $settings.showThumbnails)
                    .help(L10n.t("关闭后统一显示类型符号"))
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: 行为

private struct BehaviorSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section(L10n.t("拖放")) {
                Toggle(L10n.t("文件拖到边条上时自动展开"), isOn: $settings.expandOnDragHover)
                Text(L10n.t("关闭后，收起状态下需先点开边条再拖入文件。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(L10n.t("拖出文件后自动收起"), isOn: $settings.collapseAfterDragOut)
                Text(L10n.t("把条目拖离抽屉、拖拽结束后抽屉滑回收起边条。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L10n.t("窗口")) {
                Toggle(L10n.t("切换到其他应用时自动收起"), isOn: $settings.autoCollapseOnBlur)
                Toggle(L10n.t("清空抽屉后自动收起"), isOn: $settings.collapseWhenEmpty)
                Picker(L10n.t("面板层级"), selection: $settings.panelLevel) {
                    ForEach(DrawerPanelLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                Toggle(L10n.t("在 Dock 中显示图标"), isOn: $settings.showDockIcon)
                Text(L10n.t("关闭后仅保留菜单栏图标（菜单栏 → 设置… 可随时恢复）。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: 快捷键

private struct ShortcutSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var recording = false

    var body: some View {
        Form {
            Section(L10n.t("全局热键")) {
                Toggle(L10n.t("启用全局热键"), isOn: $settings.hotKeyEnabled)
                if settings.hotKeyEnabled {
                    LabeledContent(L10n.t("热键")) {
                        HotKeyRecorderControl(label: settings.hotKeyLabel, recording: $recording) { event in
                            guard event.keyCode != 53 else { return } // Esc = 取消录制
                            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
                            let binding = HotKeyBinding(keyCode: Int(event.keyCode), modifiers: flags)
                            // 缺 ⌘/⌥/⌃ 的组合不收录，原热键保持不变
                            guard binding.isValid else { return }
                            settings.hotKeyBinding = binding
                        }
                    }
                    Button(L10n.t("恢复默认（⌥ Space）")) {
                        settings.hotKeyBinding = HotKeyBinding(keyCode: 49, modifiers: [.option])
                    }
                }
            }
            Section {
                Text(L10n.t("热键在任意应用前台时都能展开 / 收起抽屉。组合必须包含 ⌘、⌥ 或 ⌃ 修饰键，点击右侧按键框后按下新组合即可录制。") + " ⌘F · ⌘A · ⌘1–⌘9 · ⌘↑⌘↓")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// 热键录制控件：SwiftUI 画外观，透明 NSView 层接管点击聚焦与键盘事件。
private struct HotKeyRecorderControl: View {
    let label: String
    @Binding var recording: Bool
    let onCatch: (NSEvent) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(recording ? L10n.t("请按下组合键…") : label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(recording ? Color.accentColor : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(recording ? 0.06 : 0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.18), lineWidth: 1)
                )

            if recording {
                Text(L10n.t("Esc 取消"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.t("点按录制"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .overlay(
            RecorderEventLayer(recording: $recording, onCatch: onCatch)
        )
    }
}

/// 透明事件层：点击成为 first responder，下一次按键回调给 SwiftUI。
private struct RecorderEventLayer: NSViewRepresentable {
    @Binding var recording: Bool
    let onCatch: (NSEvent) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCatch = { event in
            recording = false
            onCatch(event)
        }
        view.onCancel = {
            recording = false
        }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {}

    final class RecorderView: NSView {
        var onCatch: ((NSEvent) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            onCatch?(event)
            window?.makeFirstResponder(nil) // 触发 resign → 复位录制态
        }

        override func resignFirstResponder() -> Bool {
            onCancel?()
            return true
        }
    }
}
