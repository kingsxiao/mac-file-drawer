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

    func show() {
        if window == nil {
            // contentRect 与 SettingsView 的固定 frame 对齐，避免HostingView 留死边
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "文件抽屉设置"
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
                .tabItem { Label("通用", systemImage: "gearshape") }
            AppearanceSettingsTab()
                .tabItem { Label("外观", systemImage: "paintbrush") }
            BehaviorSettingsTab()
                .tabItem { Label("行为", systemImage: "wand.and.stars") }
            ShortcutSettingsTab()
                .tabItem { Label("快捷键", systemImage: "keyboard") }
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
            Section("启动") {
                Picker("启动时", selection: $settings.launchCollapsed) {
                    Text("展开抽屉").tag(false)
                    Text("收起为边条").tag(true)
                }
                Toggle("登录 macOS 后自动启动", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("丢弃已不存在的文件", isOn: $settings.removeMissingOnLaunch)
                Text("关闭后，指向已删除文件的条目会保留在抽屉里，直到手动移除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("列表") {
                Picker("默认排序", selection: $interaction.sortMode) {
                    ForEach(InteractionModel.SortMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Toggle("单击直接打开", isOn: $settings.openOnSingleClick)
                Text("开启后单击条目即打开文件；默认单击选中、双击打开。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("暂存维护") {
                Picker("自动清理过期条目", selection: $settings.autoClean) {
                    ForEach(AutoCleanPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                Picker("容量上限", selection: $settings.maxItems) {
                    ForEach(MaxItemsPolicy.allCases) { limit in
                        Text(limit.label).tag(limit)
                    }
                }
                Text("超出上限时淘汰最早加入的条目。移除 / 清空的条目可通过提示条「还原」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("当前条目") {
                    Text("\(store.items.count) 个")
                        .foregroundStyle(.secondary)
                }
                Button("立即清理已不存在的条目") {
                    store.removeMissing()
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            launchAtLogin = LoginItemController.isEnabled
            loginItemError = nil
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItemController.setEnabled(on)
            loginItemError = nil
        } catch {
            loginItemError = "未能\(on ? "开启" : "关闭")登录启动：\(error.localizedDescription)"
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
            Section("主题") {
                Picker("外观", selection: $settings.appearance) {
                    ForEach(DrawerAppearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("抽屉尺寸") {
                LabeledContent("宽度") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.drawerWidth, in: DrawerLayout.minWidth...DrawerLayout.maxWidth, step: 5)
                        Text("\(Int(settings.drawerWidth)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("占屏高度") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.drawerHeightRatio, in: DrawerLayout.minRatio...DrawerLayout.maxRatio)
                        Text("\(Int(settings.drawerHeightRatio * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("垂直位置", selection: $settings.verticalAlignment) {
                    ForEach(DrawerVerticalAlignment.allCases) { alignment in
                        Text(alignment.label).tag(alignment)
                    }
                }
                Picker("停靠边缘", selection: $settings.edge) {
                    ForEach(DrawerEdge.allCases) { edge in
                        Text(edge.label).tag(edge)
                    }
                }
            }
            Section("材质与列表") {
                Picker("毛玻璃浓度", selection: $settings.material) {
                    ForEach(DrawerMaterial.allCases) { material in
                        Text(material.label).tag(material)
                    }
                }
                Toggle("紧凑列表", isOn: $settings.compactRows)
                    .help("更小的瓷片与行距，同屏容纳更多条目")
                Toggle("显示文件大小", isOn: $settings.showFileSize)
                Toggle("显示加入时间", isOn: $settings.showAddedTime)
                Toggle("显示缩略图（图片 / 视频 / PDF）", isOn: $settings.showThumbnails)
                    .help("关闭后统一显示类型符号")
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
            Section("拖放") {
                Toggle("文件拖到边条上时自动展开", isOn: $settings.expandOnDragHover)
                Text("关闭后，收起状态下需先点开边条再拖入文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("拖出文件后自动收起", isOn: $settings.collapseAfterDragOut)
                Text("把条目拖离抽屉、拖拽结束后抽屉滑回收起边条。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("窗口") {
                Toggle("切换到其他应用时自动收起", isOn: $settings.autoCollapseOnBlur)
                Toggle("清空抽屉后自动收起", isOn: $settings.collapseWhenEmpty)
                Picker("面板层级", selection: $settings.panelLevel) {
                    ForEach(DrawerPanelLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                Toggle("在 Dock 中显示图标", isOn: $settings.showDockIcon)
                Text("关闭后仅保留菜单栏图标（菜单栏 → 设置… 可随时恢复）。")
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
            Section("全局热键") {
                Toggle("启用全局热键", isOn: $settings.hotKeyEnabled)
                if settings.hotKeyEnabled {
                    LabeledContent("热键") {
                        HotKeyRecorderControl(label: settings.hotKeyLabel, recording: $recording) { event in
                            guard event.keyCode != 53 else { return } // Esc = 取消录制
                            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
                            let binding = HotKeyBinding(keyCode: Int(event.keyCode), modifiers: flags)
                            // 缺 ⌘/⌥/⌃ 的组合不收录，原热键保持不变
                            guard binding.isValid else { return }
                            settings.hotKeyBinding = binding
                        }
                    }
                    Button("恢复默认（⌥ Space）") {
                        settings.hotKeyBinding = HotKeyBinding(keyCode: 49, modifiers: [.option])
                    }
                }
            }
            Section {
                Text("热键在任意应用前台时都能展开 / 收起抽屉。组合必须包含 ⌘、⌥ 或 ⌃ 修饰键，点击右侧按键框后按下新组合即可录制。")
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
            Text(recording ? "请按下组合键…" : label)
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
                Text("Esc 取消")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("点按录制")
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
