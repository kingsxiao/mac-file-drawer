import Foundation
import UniformTypeIdentifiers

// MARK: - 收件箱：把拖入的文本 / 链接物化成抽屉里的真实文件
//
// 拖入的文本片段落成 .txt、链接落成 .webloc，统一放在应用自管的 Inbox 目录里。
// 之后的一切（排序 / 缩略图 / 拖出 / QuickLook / 移动到文件夹）都走既有文件条目逻辑，
// 条目本身不需要知道「这是一段文字」。
//
// 生命周期：文件只在条目被移除、且撤销窗口关闭后才真正删除（InboxStore.sweep），
// 这样「移除 → 反悔 → 还原」永远拿得回内容。

enum InboxStore {
    /// 应用自管的收件箱目录（~/Library/Application Support/FileDrawer/Inbox），按需创建
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("FileDrawer/Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 路径是否位于收件箱内（决定移除条目后能否回收底层文件）
    static func isManaged(_ path: String, directory: URL = directory) -> Bool {
        let prefix = directory.standardizedFileURL.path + "/"
        return path.hasPrefix(prefix)
    }

    // MARK: 物化（拖入文本 / 链接 → 真实文件）

    /// 文本片段 → Inbox/名字.txt
    @discardableResult
    static func materialize(text: String, directory: URL = directory) -> URL? {
        let url = uniqueChildURL(name: snippetName(forText: text), ext: "txt", directory: directory)
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// 链接 → Inbox/名字.webloc（macOS 网页快捷方式，双击即打开）
    @discardableResult
    static func materialize(url link: URL, directory: URL = directory) -> URL? {
        guard let data = weblocData(url: link) else { return nil }
        let target = uniqueChildURL(name: snippetName(forURL: link), ext: "webloc", directory: directory)
        do {
            try data.write(to: target, options: .atomic)
            return target
        } catch {
            return nil
        }
    }

    /// .webloc 内容：单个 URL 键的属性列表
    static func weblocData(url: URL) -> Data? {
        let payload = ["URL": url.absoluteString]
        return (try? PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .xml,
            options: 0
        ))
    }

    // MARK: 命名（纯函数，可单测）

    /// 文本片段名：取第一行有内容的行，去掉文件系统非法字符，限长 40
    static func snippetName(forText text: String) -> String {
        let firstName = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .lazy
            .compactMap { sanitize($0.trimmingCharacters(in: .whitespacesAndNewlines), maxLength: 40) }
            .first
        return firstName ?? "文本片段"
    }

    /// 链接名：域名 + 末段路径，取长得有辨识度的一段
    static func snippetName(forURL url: URL) -> String {
        let host = url.host?
            .replacingOccurrences(of: "www.", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tail = sanitize(url.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "/")), maxLength: 30)
        let cleanHost = sanitize(host, maxLength: 20) ?? host
        if let tail, !tail.isEmpty {
            return "\(cleanHost) \(tail)".trimmingCharacters(in: .whitespaces)
        }
        return cleanHost.isEmpty ? "链接" : cleanHost
    }

    /// 文件名消毒：去掉路径分隔符等非法字符与控制符，压掉连续空白；全空返回 nil
    static func sanitize(_ raw: String, maxLength: Int) -> String? {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
            .union(.newlines)
        let cleaned = String(raw.unicodeScalars.map { scalar -> Character in
            illegal.contains(scalar) ? " " : Character(scalar)
        })
        let collapsed = cleaned
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let trimmed = String(collapsed.prefix(maxLength))
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 同名去重：已存在则追加 " 2"、" 3"…（上限 999，防异常场景死循环）
    static func uniqueChildURL(name: String, ext: String, directory: URL) -> URL {
        let fm = FileManager.default
        let base = directory.appendingPathComponent(name)
        let primary = base.appendingPathExtension(ext)
        if !fm.fileExists(atPath: primary.path) { return primary }
        for n in 2...999 {
            let candidate = directory
                .appendingPathComponent("\(name) \(n)")
                .appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    // MARK: 清扫

    /// 删除收件箱里不再被任何条目引用的文件（在撤销窗口结束后调用）
    static func sweep(referenced: Set<String>, directory: URL = directory) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for child in children {
            let path = child.standardizedFileURL.path
            guard !referenced.contains(path) else { continue }
            try? fm.removeItem(at: child)
        }
    }

    // MARK: 拖入载荷识别

    /// 优先文件 URL；否则把文本 / 链接物化成收件箱文件。供拖入与粘贴共用。
    static func url(fromProvider provider: NSItemProvider, directory: URL = directory) -> URL? {
        // 访达与绝大多数应用的标准形式（URL 走 _ObjectiveCBridgeable 重载，同步等待结果）
        if provider.canLoadObject(ofClass: URL.self) {
            var urlResult: URL?
            let semaphore = DispatchSemaphore(value: 0)
            _ = provider.loadObject(ofClass: URL.self) { obj, _ in
                if let url = obj { urlResult = url }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 3)
            if let url = urlResult {
                if url.isFileURL { return url }
                if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    return materialize(url: url, directory: directory)
                }
            }
        }
        let registered = provider.registeredTypeIdentifiers
        // 链接：public.url 的数据表示（URL 字符串或含 URL 键的 plist）
        if registered.contains(UTType.url.identifier) {
            var link: URL?
            let semaphore = DispatchSemaphore(value: 0)
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.url.identifier) { data, _ in
                defer { semaphore.signal() }
                guard let data else { return }
                if let string = String(data: data, encoding: .utf8) {
                    link = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
                } else if
                    let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
                    let string = plist["URL"] ?? plist["url"]
                {
                    link = URL(string: string)
                }
            }
            _ = semaphore.wait(timeout: .now() + 3)
            if let link { return materialize(url: link, directory: directory) }
        }
        // 纯文本：像链接就落 .webloc，否则落 .txt
        let textType = registered.first { $0 == UTType.utf8PlainText.identifier || $0 == UTType.plainText.identifier }
        if let textType {
            var text: String?
            let semaphore = DispatchSemaphore(value: 0)
            _ = provider.loadDataRepresentation(forTypeIdentifier: textType) { data, _ in
                defer { semaphore.signal() }
                if let data { text = String(data: data, encoding: .utf8) }
            }
            _ = semaphore.wait(timeout: .now() + 3)
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let link = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                   ["http", "https"].contains(link.scheme?.lowercased() ?? "") {
                    return materialize(url: link, directory: directory)
                }
                return materialize(text: text, directory: directory)
            }
        }
        return nil
    }
}
