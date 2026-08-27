import AppKit

// MARK: - 打开方式目录：某文件可用的应用列表（默认应用排最前，去重）

enum OpenWithCatalog {
    /// 文件可打开方式：默认应用优先，其余按系统顺序；已按 URL 去重
    static func apps(for url: URL) -> [(name: String, url: URL)] {
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        let all = NSWorkspace.shared.urlsForApplications(toOpen: url)
        var seen = Set<URL>()
        var result: [(name: String, url: URL)] = []
        for app in ([defaultApp].compactMap { $0 } + all) where seen.insert(app).inserted {
            result.append((name: appName(app), url: app))
        }
        return result
    }

    /// .app bundle 的显示名（去掉扩展名）
    static func appName(_ url: URL) -> String {
        let name = url.lastPathComponent
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// 用指定应用打开文件（打开方式子菜单入口）
    @MainActor
    static func open(_ url: URL, withApplicationAt appURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        Task {
            try? await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
        }
    }
}
