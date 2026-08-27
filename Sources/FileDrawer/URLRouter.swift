import Foundation

// MARK: - URL Scheme 自动化接口
//
// 注册 filedrawer:// scheme 后，终端 / 脚本 / 其它应用可通过 open 命令驱动抽屉：
//   open "filedrawer://add?path=/tmp/报告.pdf"
//   open "filedrawer://add?path=/tmp/a.pdf&path=/tmp/b.txt"
//   open "filedrawer://reveal?path=/tmp/报告.pdf"
//   open "filedrawer://toggle" / expand / collapse
// 路径含中文或空格时由 open 自动做百分号编码，queryItems 解码后即原始路径。

enum URLRouter {
    enum Action: Equatable {
        case add(paths: [String], group: String?)
        case reveal(path: String)
        case remove(group: String?, limit: Int)
        case clear(group: String?)
        case pin(group: String?, limit: Int)
        case unpin(group: String?, limit: Int)
        case sendToFront(group: String?, limit: Int)
        case toggle
        case expand
        case collapse
    }

    /// 解析 filedrawer:// URL；scheme / host 不认识或参数缺失返回 nil
    static func action(for url: URL) -> Action? {
        guard url.scheme?.lowercased() == "filedrawer" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        let host = (components.host ?? "").lowercased()
        let queryItems = components.queryItems ?? []
        let rawGroup = queryItems
            .first(where: { $0.name == "group" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let group = (rawGroup?.isEmpty == false) ? rawGroup : nil

        switch host {
        case "add":
            let paths = queryItems
                .filter { $0.name == "path" }
                .compactMap { $0.value }
                .filter { !$0.isEmpty }
            return paths.isEmpty ? nil : .add(paths: paths, group: group)

        case "reveal":
            guard let path = queryItems.first(where: { $0.name == "path" })?.value,
                  !path.isEmpty else { return nil }
            return .reveal(path: path)

        case "toggle":
            return .toggle

        case "expand":
            return .expand

        case "remove":
            let limit = queryItems
                .first(where: { $0.name == "limit" })?
                .value
                .flatMap { Int($0) } ?? 0
            return .remove(group: group, limit: max(0, limit))

        case "clear":
            return .clear(group: group)

        case "pin", "unpin":
            let limit = queryItems
                .first(where: { $0.name == "limit" })?
                .value
                .flatMap { Int($0) } ?? 0
            return host == "pin"
                ? .pin(group: group, limit: max(0, limit))
                : .unpin(group: group, limit: max(0, limit))

        case "send-to-front":
            let limit = queryItems
                .first(where: { $0.name == "limit" })?
                .value
                .flatMap { Int($0) } ?? 0
            return .sendToFront(group: group, limit: max(0, limit))

        case "collapse":
            return .collapse

        default:
            return nil
        }
    }
}
