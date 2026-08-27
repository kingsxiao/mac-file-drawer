import AppKit
import SwiftUI

// 程序入口：纯 AppKit 生命周期（不走 SwiftUI Scene），以便完全控制抽屉式面板。
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
