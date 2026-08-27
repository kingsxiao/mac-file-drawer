import Foundation
import os

// MARK: - 轻量诊断日志
//
// 内存环形缓冲（默认不落盘，隐私友好）+ os_log 双写（系统「控制台」可按
// subsystem 过滤）。关键路径埋点：启动、展开收起、自动化动作（URL 与快捷
// 指令共用 DrawerCommands，一处埋点双路径生效）、迁移与失败事件。
// 菜单栏「导出诊断信息…」把环境摘要 + 最近条目写成文本文件，便于排障。

@MainActor
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()

    struct Entry: Equatable {
        let date: Date
        let category: String
        let message: String
    }

    /// 环形容量（超出丢最旧）
    static let capacity = 200

    private(set) var entries: [Entry] = []

    private let osLogger = Logger(subsystem: "com.wangxiao.filedrawer", category: "drawer")

    /// 记一条（主线程）；消息不携带文件路径等敏感内容
    func log(_ category: String, _ message: String) {
        entries.append(Entry(date: Date(), category: category, message: message))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        osLogger.info("[\(category, privacy: .public)] \(message, privacy: .public)")
    }

    /// 丢弃全部（测试用）
    func reset() {
        entries.removeAll()
    }

    // MARK: 诊断报告（纯函数，可单测）

    /// 环境摘要 + 最近条目 → 文本报告
    nonisolated static func report(
        version: String,
        build: String,
        systemVersion: String,
        itemCount: Int,
        drawerCount: Int,
        entries: [Entry]
    ) -> String {
        var lines: [String] = []
        let formatter = ISO8601DateFormatter()
        lines.append("FileDrawer 诊断信息")
        lines.append("版本: \(version) (\(build))")
        lines.append("系统: macOS \(systemVersion)")
        lines.append("条目: \(itemCount) 个 / \(drawerCount) 组")
        lines.append("日志条目: \(entries.count)")
        lines.append("---")
        for entry in entries {
            lines.append("\(formatter.string(from: entry.date)) [\(entry.category)] \(entry.message)")
        }
        return lines.joined(separator: "\n")
    }

    /// 生成当前实例的报告（供菜单导出）
    func currentReport() -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
        let store = ShelfStore.shared
        return Self.report(
            version: version,
            build: build,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            itemCount: store.items.count,
            drawerCount: store.drawers.count,
            entries: entries
        )
    }
}
