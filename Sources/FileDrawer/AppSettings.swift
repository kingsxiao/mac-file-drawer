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
        case .system: return L10n.t("跟随系统")
        case .light: return L10n.t("浅色")
        case .dark: return L10n.t("深色")
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
        case .center: return L10n.t("居中")
        case .top: return L10n.t("靠上")
        case .bottom: return L10n.t("靠下")
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
        case .floating: return L10n.t("浮动在其他窗口之上")
        case .normal: return L10n.t("普通窗口层级")
        }
    }

    var nsLevel: NSWindow.Level {
        switch self {
        case .floating: return .floating
        case .normal: return .normal
        }
    }
}

/// 抽屉底色材质（毛玻璃浓度）
enum DrawerMaterial: Int, CaseIterable, Identifiable {
    case ultraThin
    case thin
    case thick
    case ultraThick

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .ultraThin: return L10n.t("超薄")
        case .thin: return L10n.t("薄")
        case .thick: return L10n.t("厚")
        case .ultraThick: return L10n.t("超厚")
        }
    }

    var material: Material {
        switch self {
        case .ultraThin: return .ultraThinMaterial
        case .thin: return .thinMaterial
        case .thick: return .thickMaterial
        case .ultraThick: return .ultraThickMaterial
        }
    }
}

/// 抽屉停靠的屏幕边缘（拉手与圆角在贴边侧的对侧）
enum DrawerEdge: Int, CaseIterable, Identifiable {
    case right
    case left

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .right: return L10n.t("右侧")
        case .left: return L10n.t("左侧")
        }
    }
}

/// 过期条目自动清理策略
enum AutoCleanPolicy: Int, CaseIterable, Identifiable {
    case off
    case oneDay
    case week
    case month

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off: return L10n.t("关闭")
        case .oneDay: return L10n.t("1 天后")
        case .week: return L10n.t("7 天后")
        case .month: return L10n.t("30 天后")
        }
    }

    var days: Int? {
        switch self {
        case .off: return nil
        case .oneDay: return 1
        case .week: return 7
        case .month: return 30
        }
    }
}

/// 抽屉容量上限（超出时淘汰最早加入的条目）
enum MaxItemsPolicy: Int, CaseIterable, Identifiable {
    case unlimited
    case m20
    case m50
    case m100

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .unlimited: return L10n.t("不限制")
        case .m20: return L10n.t("20 条")
        case .m50: return L10n.t("50 条")
        case .m100: return L10n.t("100 条")
        }
    }

    var count: Int? {
        switch self {
        case .unlimited: return nil
        case .m20: return 20
        case .m50: return 50
        case .m100: return 100
        }
    }
}

/// 界面语言
enum AppLanguage: Int, CaseIterable, Identifiable {
    case system
    case chinese
    case english

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .system: return L10n.t("跟随系统")
        case .chinese: return "中文"
        case .english: return "English"
        }
    }

    /// 传给 L10n 的语言代码；nil = 跟随系统
    var code: String? {
        switch self {
        case .system: return nil
        case .chinese: return "zh-Hans"
        case .english: return "en"
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
        var symbol = ""
        if modifiers.contains(.control) { symbol += "⌃" }
        if modifiers.contains(.option) { symbol += "⌥" }
        if modifiers.contains(.shift) { symbol += "⇧" }
        if modifiers.contains(.command) { symbol += "⌘" }
        let key = Self.string(forKeyCode: keyCode)
        // macOS 惯例：单字符键紧贴符号（⌘S），单词键名留空格（⌥ Space）
        return key.count > 1 ? "\(symbol) \(key)" : symbol + key
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
        keyLabels[code] ?? L10n.tf("键码 %d", code)
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
        static let openOnSingleClick = prefix + "openOnSingleClick"
        static let collapseAfterDragOut = prefix + "collapseAfterDragOut"
        static let collapseWhenEmpty = prefix + "collapseWhenEmpty"
        static let showFileSize = prefix + "showFileSize"
        static let showAddedTime = prefix + "showAddedTime"
        static let compactRows = prefix + "compactRows"
        static let autoClean = prefix + "autoClean"
        static let maxItems = prefix + "maxItems"
        static let material = prefix + "material"
        static let edge = prefix + "edge"
        static let showDockIcon = prefix + "showDockIcon"
        static let followMouseScreen = prefix + "followMouseScreen"
        static let searchFileContents = prefix + "searchFileContents"
        static let language = prefix + "language"
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
    /// 抽屉底色材质
    @Published var material: DrawerMaterial {
        didSet { defaults.set(material.rawValue, forKey: Keys.material) }
    }
    /// 停靠屏幕边缘（左 / 右）
    @Published var edge: DrawerEdge {
        didSet { defaults.set(edge.rawValue, forKey: Keys.edge) }
    }
    /// 在 Dock 中显示应用图标（关闭后只保留菜单栏图标，典型工具类应用形态）
    @Published var showDockIcon: Bool {
        didSet { defaults.set(showDockIcon, forKey: Keys.showDockIcon) }
    }
    /// 多显示器：展开时停靠到鼠标所在屏幕（关闭则始终主屏幕）
    @Published var followMouseScreen: Bool {
        didSet { defaults.set(followMouseScreen, forKey: Keys.followMouseScreen) }
    }
    /// 搜索时也匹配文件内容（Spotlight kMDItemTextContent）
    @Published var searchFileContents: Bool {
        didSet { defaults.set(searchFileContents, forKey: Keys.searchFileContents) }
    }
    /// 界面语言
    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }

    // MARK: 交互

    /// 单击条目直接打开（默认关闭：单击选中、双击打开）
    @Published var openOnSingleClick: Bool {
        didSet { defaults.set(openOnSingleClick, forKey: Keys.openOnSingleClick) }
    }
    /// 把文件拖出抽屉、拖拽会话结束后自动收起
    @Published var collapseAfterDragOut: Bool {
        didSet { defaults.set(collapseAfterDragOut, forKey: Keys.collapseAfterDragOut) }
    }
    /// 抽屉被清空后自动收起
    @Published var collapseWhenEmpty: Bool {
        didSet { defaults.set(collapseWhenEmpty, forKey: Keys.collapseWhenEmpty) }
    }

    // MARK: 列表显示

    /// 元信息行显示文件大小
    @Published var showFileSize: Bool {
        didSet { defaults.set(showFileSize, forKey: Keys.showFileSize) }
    }
    /// 元信息行显示加入时间
    @Published var showAddedTime: Bool {
        didSet { defaults.set(showAddedTime, forKey: Keys.showAddedTime) }
    }
    /// 紧凑行（更小的瓷片与行距）
    @Published var compactRows: Bool {
        didSet { defaults.set(compactRows, forKey: Keys.compactRows) }
    }

    // MARK: 维护

    /// 过期条目自动清理
    @Published var autoClean: AutoCleanPolicy {
        didSet { defaults.set(autoClean.rawValue, forKey: Keys.autoClean) }
    }
    /// 容量上限（超出淘汰最早加入）
    @Published var maxItems: MaxItemsPolicy {
        didSet { defaults.set(maxItems.rawValue, forKey: Keys.maxItems) }
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

    /// 便捷读写：无效组合（无功能修饰键）在 get 侧归零为 nil；
    /// set 侧同样拒绝无效组合——否则垃圾值落库后 get 变 nil，
    /// 应用侧会把已注册的热键注销，而界面还显示着无效组合的假标签。
    var hotKeyBinding: HotKeyBinding? {
        get {
            let binding = HotKeyBinding(
                keyCode: hotKeyCode,
                modifiers: NSEvent.ModifierFlags(rawValue: UInt(truncatingIfNeeded: hotKeyModifiers))
            )
            return binding.isValid ? binding : nil
        }
        set {
            guard let newValue, newValue.isValid else { return }
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
        material = DrawerMaterial(rawValue: defaults.integer(forKey: Keys.material)) ?? .ultraThin
        edge = DrawerEdge(rawValue: defaults.integer(forKey: Keys.edge)) ?? .right
        showDockIcon = defaults.object(forKey: Keys.showDockIcon) as? Bool ?? true
        followMouseScreen = defaults.bool(forKey: Keys.followMouseScreen)
        searchFileContents = defaults.object(forKey: Keys.searchFileContents) as? Bool ?? true
        language = AppLanguage(rawValue: defaults.integer(forKey: Keys.language)) ?? .system
        openOnSingleClick = defaults.bool(forKey: Keys.openOnSingleClick)
        collapseAfterDragOut = defaults.bool(forKey: Keys.collapseAfterDragOut)
        collapseWhenEmpty = defaults.bool(forKey: Keys.collapseWhenEmpty)
        showFileSize = defaults.object(forKey: Keys.showFileSize) as? Bool ?? true
        showAddedTime = defaults.object(forKey: Keys.showAddedTime) as? Bool ?? true
        compactRows = defaults.bool(forKey: Keys.compactRows)
        autoClean = AutoCleanPolicy(rawValue: defaults.integer(forKey: Keys.autoClean)) ?? .off
        maxItems = MaxItemsPolicy(rawValue: defaults.integer(forKey: Keys.maxItems)) ?? .unlimited
        hotKeyEnabled = defaults.bool(forKey: Keys.hotKeyEnabled)
        hotKeyCode = defaults.object(forKey: Keys.hotKeyCode) as? Int ?? 49
        hotKeyModifiers = defaults.object(forKey: Keys.hotKeyModifiers) as? Int
            ?? Int(NSEvent.ModifierFlags.option.rawValue)
        hotKeyLabel = defaults.string(forKey: Keys.hotKeyLabel) ?? "⌥ Space"
    }
}
