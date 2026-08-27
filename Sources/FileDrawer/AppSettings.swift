import AppKit
import SwiftUI

// MARK: - 设置项类型（文件级声明，纯逻辑可在任何隔离上下文使用）

/// 外观主题
enum DrawerAppearance: Int, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// 展开态抽屉的垂直停靠位置
enum DrawerVerticalAlignment: Int, CaseIterable, Identifiable {
    case center
    case top
    case bottom

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .center: return "居中"
        case .top: return "靠上"
        case .bottom: return "靠下"
        }
    }
}

/// 抽屉面板的窗口层级
enum DrawerPanelLevel: Int, CaseIterable, Identifiable {
    case floating
    case normal

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .floating: return "浮动在其他窗口之上"
        case .normal: return "普通窗口层级"
        }
    }

    var nsLevel: NSWindow.Level {
        switch self {
        case .floating: return .floating
        case .normal: return .normal
        }
    }
}

/// 全局热键：键码 + 修饰键（注册走 Carbon RegisterEventHotKey）
struct HotKeyBinding: Equatable {
    var keyCode: Int
    var modifiers: NSEvent.ModifierFlags

    /// 必须带至少一个功能修饰键（⌘/⌥/⌃），避免吞掉普通按键
    var isValid: Bool {
        keyCode > 0 && !modifiers.intersection([.command, .option, .control]).isEmpty
    }

    var displayLabel: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(Self.string(forKeyCode: keyCode))
        return parts.joined()
    }

    /// macOS 虚拟键码 → 显示字符（ANSI 布局）
    static let keyLabels: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        24: "=", 27: "-", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "Esc",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func string(forKeyCode code: Int) -> String {
        keyLabels[code] ?? "键码 \(code)"
    }
}

// MARK: - 应用设置
// 集中式配置模型：所有可调项在这里定义并持久化到 UserDefaults。
// 设置面板（SettingsView）与窗口逻辑（AppDelegate / DrawerLayout）共享同一实例。

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let prefix = "com.wangxiao.filedrawer.settings."
        static let launchCollapsed = prefix + "launchCollapsed"
        static let removeMissingOnLaunch = prefix + "removeMissingOnLaunch"
        static let appearance = prefix + "appearance"
        static let drawerWidth = prefix + "drawerWidth"
        static let drawerHeightRatio = prefix + "drawerHeightRatio"
        static let verticalAlignment = prefix + "verticalAlignment"
        static let showThumbnails = prefix + "showThumbnails"
        static let expandOnDragHover = prefix + "expandOnDragHover"
        static let autoCollapseOnBlur = prefix + "autoCollapseOnBlur"
        static let panelLevel = prefix + "panelLevel"
        static let hotKeyEnabled = prefix + "hotKeyEnabled"
        static let hotKeyCode = prefix + "hotKeyCode"
        static let hotKeyModifiers = prefix + "hotKeyModifiers"
        static let hotKeyLabel = prefix + "hotKeyLabel"
    }

    private let defaults: UserDefaults

    // MARK: 通用

    /// 启动时收起为边条（否则展开抽屉）
    @Published var launchCollapsed: Bool {
        didSet { defaults.set(launchCollapsed, forKey: Keys.launchCollapsed) }
    }
    /// 启动时丢弃硬盘中已不存在的条目
    @Published var removeMissingOnLaunch: Bool {
        didSet { defaults.set(removeMissingOnLaunch, forKey: Keys.removeMissingOnLaunch) }
    }

    // MARK: 外观

    @Published var appearance: DrawerAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    /// 抽屉宽度（pt），有效范围见 DrawerLayout
    @Published var drawerWidth: Double {
        didSet {
            let clamped = min(max(drawerWidth, DrawerLayout.minWidth), DrawerLayout.maxWidth)
            if clamped != drawerWidth {
                drawerWidth = clamped // 触发一次递归 didSet 后落库
            } else {
                defaults.set(clamped, forKey: Keys.drawerWidth)
            }
        }
    }
    /// 抽屉高度占屏幕可视高度的比例；1.0 时上下各留呼吸边距
    @Published var drawerHeightRatio: Double {
        didSet {
            let clamped = min(max(drawerHeightRatio, DrawerLayout.minRatio), DrawerLayout.maxRatio)
            if clamped != drawerHeightRatio {
                drawerHeightRatio = clamped
            } else {
                defaults.set(clamped, forKey: Keys.drawerHeightRatio)
            }
        }
    }
    @Published var verticalAlignment: DrawerVerticalAlignment {
        didSet { defaults.set(verticalAlignment.rawValue, forKey: Keys.verticalAlignment) }
    }
    /// 图片 / 视频条目显示真实缩略图
    @Published var showThumbnails: Bool {
        didSet { defaults.set(showThumbnails, forKey: Keys.showThumbnails) }
    }

    // MARK: 行为

    /// 拖文件悬停到收起边条上时自动展开接收
    @Published var expandOnDragHover: Bool {
        didSet { defaults.set(expandOnDragHover, forKey: Keys.expandOnDragHover) }
    }
    /// 切换到其他应用时自动收起抽屉
    @Published var autoCollapseOnBlur: Bool {
        didSet { defaults.set(autoCollapseOnBlur, forKey: Keys.autoCollapseOnBlur) }
    }
    @Published var panelLevel: DrawerPanelLevel {
        didSet { defaults.set(panelLevel.rawValue, forKey: Keys.panelLevel) }
    }

    // MARK: 快捷键

    @Published var hotKeyEnabled: Bool {
        didSet { defaults.set(hotKeyEnabled, forKey: Keys.hotKeyEnabled) }
    }
    @Published var hotKeyCode: Int {
        didSet { defaults.set(hotKeyCode, forKey: Keys.hotKeyCode) }
    }
    /// NSEvent.ModifierFlags.rawValue 的 Int 表示
    @Published var hotKeyModifiers: Int {
        didSet { defaults.set(hotKeyModifiers, forKey: Keys.hotKeyModifiers) }
    }
    /// 最近一次录制的显示文案（如 "⌥ Space"）
    @Published var hotKeyLabel: String {
        didSet { defaults.set(hotKeyLabel, forKey: Keys.hotKeyLabel) }
    }

    /// 便捷读写：无效组合（无功能修饰键）在 get 侧归零为 nil
    var hotKeyBinding: HotKeyBinding? {
        get {
            let binding = HotKeyBinding(
                keyCode: hotKeyCode,
                modifiers: NSEvent.ModifierFlags(rawValue: UInt(truncatingIfNeeded: hotKeyModifiers))
            )
            return binding.isValid ? binding : nil
        }
        set {
            guard let newValue else { return }
            hotKeyCode = newValue.keyCode
            hotKeyModifiers = Int(newValue.modifiers.rawValue)
            hotKeyLabel = newValue.displayLabel
        }
    }

    /// 应用代码用 shared；测试可注入独立 defaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchCollapsed = defaults.bool(forKey: Keys.launchCollapsed)
        removeMissingOnLaunch = defaults.object(forKey: Keys.removeMissingOnLaunch) as? Bool ?? true
        appearance = DrawerAppearance(rawValue: defaults.integer(forKey: Keys.appearance)) ?? .system
        drawerWidth = defaults.object(forKey: Keys.drawerWidth) as? Double ?? 330
        drawerHeightRatio = defaults.object(forKey: Keys.drawerHeightRatio) as? Double ?? 1.0
        verticalAlignment = DrawerVerticalAlignment(rawValue: defaults.integer(forKey: Keys.verticalAlignment)) ?? .center
        showThumbnails = defaults.object(forKey: Keys.showThumbnails) as? Bool ?? true
        expandOnDragHover = defaults.object(forKey: Keys.expandOnDragHover) as? Bool ?? true
        autoCollapseOnBlur = defaults.object(forKey: Keys.autoCollapseOnBlur) as? Bool ?? false
        panelLevel = DrawerPanelLevel(rawValue: defaults.integer(forKey: Keys.panelLevel)) ?? .floating
        hotKeyEnabled = defaults.bool(forKey: Keys.hotKeyEnabled)
        hotKeyCode = defaults.object(forKey: Keys.hotKeyCode) as? Int ?? 49
        hotKeyModifiers = defaults.object(forKey: Keys.hotKeyModifiers) as? Int
            ?? Int(NSEvent.ModifierFlags.option.rawValue)
        hotKeyLabel = defaults.string(forKey: Keys.hotKeyLabel) ?? "⌥ Space"
    }
}
