import XCTest
import AppKit
@testable import FileDrawer

/// 设置窗口：可缩放、最小尺寸（小屏可用性）、show 复用同一窗口
final class SettingsWindowTests: XCTestCase {

    @MainActor
    func testSettingsWindowIsResizableWithMinSize() {
        let manager = SettingsWindowManager.shared
        manager.show()
        let window = manager.window
        XCTAssertNotNil(window)
        XCTAssertTrue(window?.styleMask.contains(.resizable) ?? false, "设置窗口应可缩放（小屏可缩小使用）")
        XCTAssertTrue(window?.styleMask.contains(.miniaturizable) ?? false)
        XCTAssertEqual(window?.contentMinSize.width ?? 0, 460, accuracy: 0.5)
        XCTAssertEqual(window?.contentMinSize.height ?? 0, 400, accuracy: 0.5, "最小高度 400pt 适配高度 <500 的小屏")
        window?.close()

        // 复用：再次 show 得到同一实例（isReleasedWhenClosed=false）
        manager.show()
        XCTAssertTrue(manager.window === window, "设置窗口应复用同一实例")
        manager.window?.close()
    }
}
