import AppKit
import SwiftUI

// MARK: - 设置窗口管理

@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()

    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
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

    var body: some View {
        Form {
            Section("启动") {
                Picker("启动时", selection: $settings.launchCollapsed) {
                    Text("展开抽屉").tag(false)
                    Text("收起为边条").tag(true)
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
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: .infinity, alignment: .top)
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
            }
            Section("内容") {
                Toggle("显示图片 / 视频缩略图", isOn: $settings.showThumbnails)
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
            }
            Section("窗口") {
                Toggle("切换到其他应用时自动收起", isOn: $settings.autoCollapseOnBlur)
                Picker("面板层级", selection: $settings.panelLevel) {
                    ForEach(DrawerPanelLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
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
                            settings.hotKeyBinding = HotKeyBinding(keyCode: Int(event.keyCode), modifiers: flags)
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
