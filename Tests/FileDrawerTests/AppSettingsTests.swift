import XCTest
import AppKit
import Carbon.HIToolbox
@testable import FileDrawer

/// 设置模型 / 布局计算 / 全局热键的行为契约
final class AppSettingsTests: XCTestCase {

    private func makeDefaults() -> (defaults: UserDefaults, name: String) {
        let name = "FileDrawerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, name)
    }

    // MARK: - 默认值

    func testDefaultValues() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        MainActor.assumeIsolated {
            let s = AppSettings(defaults: defaults)
            XCTAssertFalse(s.launchCollapsed)
            XCTAssertTrue(s.removeMissingOnLaunch)
            XCTAssertEqual(s.appearance, .system)
            XCTAssertEqual(s.drawerWidth, 330, accuracy: 0.01)
            XCTAssertEqual(s.drawerHeightRatio, 1.0, accuracy: 0.0001)
            XCTAssertEqual(s.verticalAlignment, .center)
            XCTAssertTrue(s.showThumbnails)
            XCTAssertTrue(s.expandOnDragHover)
            XCTAssertFalse(s.autoCollapseOnBlur)
            XCTAssertEqual(s.panelLevel, .floating)
            XCTAssertFalse(s.hotKeyEnabled)
            XCTAssertEqual(s.hotKeyBinding?.keyCode, 49)
            XCTAssertEqual(s.hotKeyBinding?.modifiers, .option)
            XCTAssertTrue(s.showDockIcon, "Dock 图标默认开启，保持既有形态")
            XCTAssertFalse(s.followMouseScreen, "多屏跟随鼠标默认关闭（主屏停靠）")
        }
    }

    // MARK: - 持久化往返

    func testPersistRoundTrip() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        MainActor.assumeIsolated {
            let s = AppSettings(defaults: defaults)
            s.launchCollapsed = true
            s.removeMissingOnLaunch = false
            s.appearance = .dark
            s.drawerWidth = 380
            s.drawerHeightRatio = 0.7
            s.verticalAlignment = .top
            s.showThumbnails = false
            s.expandOnDragHover = false
            s.autoCollapseOnBlur = true
            s.panelLevel = .normal
            s.showDockIcon = false
            s.followMouseScreen = true
            s.hotKeyEnabled = true
            s.hotKeyBinding = HotKeyBinding(keyCode: 1, modifiers: [.command, .shift])

            let reloaded = AppSettings(defaults: defaults)
            XCTAssertTrue(reloaded.launchCollapsed)
            XCTAssertFalse(reloaded.removeMissingOnLaunch)
            XCTAssertEqual(reloaded.appearance, .dark)
            XCTAssertEqual(reloaded.drawerWidth, 380, accuracy: 0.01)
            XCTAssertEqual(reloaded.drawerHeightRatio, 0.7, accuracy: 0.0001)
            XCTAssertEqual(reloaded.verticalAlignment, .top)
            XCTAssertFalse(reloaded.showThumbnails)
            XCTAssertFalse(reloaded.expandOnDragHover)
            XCTAssertTrue(reloaded.autoCollapseOnBlur)
            XCTAssertEqual(reloaded.panelLevel, .normal)
            XCTAssertFalse(reloaded.showDockIcon)
            XCTAssertTrue(reloaded.followMouseScreen, "跟随鼠标屏幕的设置应持久化")
            XCTAssertTrue(reloaded.hotKeyEnabled)
            XCTAssertEqual(reloaded.hotKeyBinding?.keyCode, 1)
            XCTAssertEqual(reloaded.hotKeyBinding?.modifiers, [.command, .shift])
            XCTAssertEqual(reloaded.hotKeyLabel, "⇧⌘S")
        }
    }

    // MARK: - 数值夹取

    func testDrawerWidthClampedToBounds() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        MainActor.assumeIsolated {
            let s = AppSettings(defaults: defaults)
            s.drawerWidth = 100
            XCTAssertEqual(s.drawerWidth, DrawerLayout.minWidth, accuracy: 0.01)
            s.drawerWidth = 9999
            XCTAssertEqual(s.drawerWidth, DrawerLayout.maxWidth, accuracy: 0.01)

            s.drawerHeightRatio = 0.1
            XCTAssertEqual(s.drawerHeightRatio, DrawerLayout.minRatio, accuracy: 0.0001)
            s.drawerHeightRatio = 2.0
            XCTAssertEqual(s.drawerHeightRatio, DrawerLayout.maxRatio, accuracy: 0.0001)
        }
    }

    // MARK: - 布局计算

    func testLayoutGeometry() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        MainActor.assumeIsolated {
            let s = AppSettings(defaults: defaults)
            let vf = NSRect(x: 0, y: 0, width: 1512, height: 900)

            // 默认：宽 330，高 = 可视高 - 上下呼吸边距
            let size = DrawerLayout.expandedSize(visibleFrame: vf, settings: s)
            XCTAssertEqual(size.width, 330, accuracy: 0.01)
            XCTAssertEqual(size.height, 900 - 48, accuracy: 0.01)

            // 居中：贴右缘 + 垂直居中
            let center = DrawerLayout.expandedFrame(visibleFrame: vf, settings: s)
            XCTAssertEqual(center.maxX, vf.maxX, accuracy: 0.01)
            XCTAssertEqual(center.midY, vf.midY, accuracy: 0.01)

            // 靠上 / 靠下
            s.verticalAlignment = .top
            XCTAssertEqual(DrawerLayout.expandedFrame(visibleFrame: vf, settings: s).maxY, vf.maxY, accuracy: 0.01)
            s.verticalAlignment = .bottom
            XCTAssertEqual(DrawerLayout.expandedFrame(visibleFrame: vf, settings: s).minY, vf.minY, accuracy: 0.01)

            // 高度比例
            s.drawerHeightRatio = 0.5
            XCTAssertEqual(
                DrawerLayout.expandedSize(visibleFrame: vf, settings: s).height,
                (900 - 48) * 0.5,
                accuracy: 0.01
            )

            // 收起边条：46 宽、垂直居中、贴右缘
            let collapsed = DrawerLayout.collapsedFrame(visibleFrame: vf, settings: s)
            XCTAssertEqual(collapsed.width, 46, accuracy: 0.01)
            XCTAssertEqual(collapsed.maxX, vf.maxX, accuracy: 0.01)
            XCTAssertEqual(collapsed.midY, vf.midY, accuracy: 0.01)

            // 屏幕外：完全在右缘之外
            let offscreen = DrawerLayout.offscreenFrame(visibleFrame: vf, settings: s)
            XCTAssertEqual(offscreen.minX, vf.maxX + 4, accuracy: 0.01)

            // 左缘停靠：贴左缘，收起边条与屏幕外都朝左
            s.edge = .left
            let leftExpanded = DrawerLayout.expandedFrame(visibleFrame: vf, settings: s)
            XCTAssertEqual(leftExpanded.minX, vf.minX, accuracy: 0.01)
            let leftCollapsed = DrawerLayout.collapsedFrame(visibleFrame: vf, settings: s)
            XCTAssertEqual(leftCollapsed.minX, vf.minX, accuracy: 0.01)
            let leftOffscreen = DrawerLayout.offscreenFrame(visibleFrame: vf, settings: s)
            XCTAssertEqual(leftOffscreen.maxX, vf.minX - 4, accuracy: 0.01)
        }
    }

    func testLayoutClampsYOnTinyScreen() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        MainActor.assumeIsolated {
            let s = AppSettings(defaults: defaults)
            // 比最小抽屉高度还矮的可视区：y 不能为负
            let vf = NSRect(x: 0, y: 0, width: 1000, height: 300)
            s.verticalAlignment = .top
            let frame = DrawerLayout.expandedFrame(visibleFrame: vf, settings: s)
            XCTAssertGreaterThanOrEqual(frame.minY, vf.minY)
            XCTAssertEqual(frame.height, DrawerLayout.minDrawerHeight, accuracy: 0.01)
        }
    }

    // MARK: - 热键

    func testCarbonModifierConversion() {
        XCTAssertEqual(HotKeyCenter.carbonModifiers(from: [.command]), cmdKey)
        XCTAssertEqual(HotKeyCenter.carbonModifiers(from: [.option]), optionKey)
        XCTAssertEqual(HotKeyCenter.carbonModifiers(from: [.control]), controlKey)
        XCTAssertEqual(HotKeyCenter.carbonModifiers(from: [.shift]), shiftKey)
        XCTAssertEqual(HotKeyCenter.carbonModifiers(from: [.command, .option]), cmdKey | optionKey)
        XCTAssertEqual(HotKeyCenter.carbonModifiers(from: [.function]), 0)
        XCTAssertEqual(HotKeyCenter.carbonModifiers(from: []), 0)
    }

    func testHotKeyBindingLabelAndValidity() {
        XCTAssertEqual(HotKeyBinding(keyCode: 49, modifiers: [.option]).displayLabel, "⌥ Space")
        XCTAssertEqual(HotKeyBinding(keyCode: 0, modifiers: [.command, .shift]).displayLabel, "⇧⌘A")
        XCTAssertEqual(HotKeyBinding(keyCode: 122, modifiers: [.control, .option]).displayLabel, "⌃⌥ F1")

        // 必须带 ⌘/⌥/⌃；⇧ 单独无效；键码 0 无效
        XCTAssertTrue(HotKeyBinding(keyCode: 49, modifiers: [.option]).isValid)
        XCTAssertFalse(HotKeyBinding(keyCode: 49, modifiers: [.shift]).isValid)
        XCTAssertFalse(HotKeyBinding(keyCode: 49, modifiers: []).isValid)
        XCTAssertFalse(HotKeyBinding(keyCode: 0, modifiers: [.command]).isValid)

        XCTAssertEqual(HotKeyBinding.string(forKeyCode: 49), "Space")
        XCTAssertEqual(HotKeyBinding.string(forKeyCode: 126), "↑")
        XCTAssertEqual(HotKeyBinding.string(forKeyCode: 99), "F3")
    }

    func testHotKeyInvalidBindingResolvesToNil() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        MainActor.assumeIsolated {
            let s = AppSettings(defaults: defaults)
            s.hotKeyCode = 49
            s.hotKeyModifiers = Int(NSEvent.ModifierFlags.shift.rawValue) // 仅 ⇧ → 无效
            XCTAssertNil(s.hotKeyBinding)
        }
    }

    /// 录到无效组合（缺 ⌘/⌥/⌃）时不得落库：否则 get 侧归 nil，
    /// 应用会把已注册热键注销，而界面还显示着无效组合的假标签
    func testHotKeyBindingSetterRejectsInvalidCombos() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        MainActor.assumeIsolated {
            let s = AppSettings(defaults: defaults)
            s.hotKeyBinding = HotKeyBinding(keyCode: 1, modifiers: [.command])
            XCTAssertEqual(s.hotKeyLabel, "⌘S")

            s.hotKeyBinding = HotKeyBinding(keyCode: 2, modifiers: [])      // 无修饰键
            s.hotKeyBinding = HotKeyBinding(keyCode: 2, modifiers: [.shift]) // 仅 ⇧
            XCTAssertEqual(s.hotKeyCode, 1, "无效组合不应覆盖已录制热键")
            XCTAssertEqual(s.hotKeyLabel, "⌘S")
            XCTAssertNotNil(s.hotKeyBinding)
        }
    }

    func testHotKeyCenterRegisterLifecycle() {
        MainActor.assumeIsolated {
            HotKeyCenter.shared.update(HotKeyBinding(keyCode: 49, modifiers: [.option])) {}
            XCTAssertEqual(HotKeyCenter.shared.isRegistered, true)
            HotKeyCenter.shared.unregister()
            XCTAssertFalse(HotKeyCenter.shared.isRegistered)
            // binding 为 nil 时安全无副作用
            HotKeyCenter.shared.update(nil) {}
            XCTAssertFalse(HotKeyCenter.shared.isRegistered)
        }
    }
}
