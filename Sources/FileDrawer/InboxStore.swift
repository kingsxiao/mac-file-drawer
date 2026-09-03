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

    /// 任意文件名（可无扩展名）在目标目录内的不冲突版本：已存在则追加 " 2"、" 3"…
    static func uniqueSiblingURL(fileName: String, directory: URL) -> URL {
        let fm = FileManager.default
        let primary = directory.appendingPathComponent(fileName)
        if !fm.fileExists(atPath: primary.path) { return primary }
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        for n in 2...999 {
            let candidate = directory.appendingPathComponent(
                ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            )
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent(UUID().uuidString)
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

    /// 可接收并物化成收件箱文件的「媒体文件」类型（图像 / 视频 / 音频 / PDF）。
    /// 显式白名单而不是笼统的 public.data：既覆盖照片（HEIC）、浏览器拖图（TIFF）、
    /// 附件（PDF）等高频来源，又不会让任意数据型拖拽都把抽屉当成落点。
    static let receivableFileTypes: [UTType] = [.image, .movie, .audio, .pdf]
    static let receivableFileTypeIdentifiers = receivableFileTypes.map(\.identifier)

    /// 注册类型是否可物化（按 UTI conformance 判定，具体类型如 public.heic 天然命中）
    static func isReceivableFileType(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        return receivableFileTypes.contains { type.conforms(to: $0) }
    }

    /// 优先文件 URL；图像 / 媒体承诺物化进收件箱；否则文本 / 链接物化。供拖入与粘贴共用。
    static func url(fromProvider provider: NSItemProvider, directory: URL = directory) -> URL? {
        let registered = provider.registeredTypeIdentifiers

        // 访达与绝大多数应用的标准形式（URL 走 _ObjectiveCBridgeable 重载，同步等待结果）。
        // 只把「真实文件」当场返回；网页链接先记下，图像 / 媒体载荷优先于链接物化
        // （浏览器拖图同时携带图像数据与 URL，用户要的是那张图而不是一个 webloc）
        var webLink: URL?
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
                    webLink = url
                }
            }
        }

        // 图像载荷：浏览器 / 编辑器拖出的图（数据表示），或照片拖出的承诺图
        if let imageType = registered.first(where: { UTType($0)?.conforms(to: .image) ?? false }),
           let file = receiveFile(provider, typeIdentifier: imageType, directory: directory) {
            return file
        }

        // 其余媒体文件承诺：照片视频（movie）、音频、PDF 附件等
        if let fileType = registered.first(where: isReceivableFileType),
           let file = receiveFile(provider, typeIdentifier: fileType, directory: directory) {
            return file
        }

        // 链接：loadObject 拿到的 http(s) URL，或 public.url 的数据表示（URL 字符串 / 含 URL 键的 plist）
        if let webLink, let materialized = materialize(url: webLink, directory: directory) {
            return materialized
        }
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

    // MARK: 文件承诺 / 文件表示接收

    /// 把 provider 的图像 / 媒体载荷收进收件箱，返回收件箱内的文件 URL。
    ///
    /// 路径一（首选）：`loadFileRepresentation` —— 文件承诺（照片 / 附件）由此履约，
    /// 仅注册了数据表示的 provider 也会被系统 coerce 成临时文件；交付的 URL 只在
    /// 回调内有效，必须在回调里立即移动。
    /// 路径二（兜底）：`loadDataRepresentation` 自写文件（扩展名取注册类型的惯用扩展），
    /// 覆盖系统不 coerce 的场景。
    static func receiveFile(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        directory: URL
    ) -> URL? {
        let suggestedName = provider.suggestedName
        var received: URL?
        let semaphore = DispatchSemaphore(value: 0)
        _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
            defer { semaphore.signal() }
            guard let url else { return }
            received = importDeliveredFile(
                url,
                suggestedName: suggestedName,
                typeIdentifier: typeIdentifier,
                directory: directory
            )
        }
        _ = semaphore.wait(timeout: .now() + 10)

        if let received { return received }

        var payload: Data?
        let dataSemaphore = DispatchSemaphore(value: 0)
        _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
            defer { dataSemaphore.signal() }
            payload = data
        }
        _ = dataSemaphore.wait(timeout: .now() + 3)
        guard let payload, !payload.isEmpty else { return nil }

        let ext = UTType(typeIdentifier)?.preferredFilenameExtension ?? "dat"
        let stem = suggestedName
            .flatMap { sanitize(($0 as NSString).deletingPathExtension, maxLength: 40) }
            ?? fallbackMediaName(for: typeIdentifier)
        let target = uniqueChildURL(name: stem, ext: ext, directory: directory)
        do {
            try payload.write(to: target, options: .atomic)
            return target
        } catch {
            return nil
        }
    }

    /// 把 loadFileRepresentation 交付的（临时）文件移动进收件箱；跨卷等场景退化为拷贝
    static func importDeliveredFile(
        _ source: URL,
        suggestedName: String?,
        typeIdentifier: String,
        directory: URL
    ) -> URL? {
        let ext = source.pathExtension.isEmpty
            ? UTType(typeIdentifier)?.preferredFilenameExtension ?? "dat"
            : source.pathExtension
        let stem = suggestedName.flatMap { sanitize(($0 as NSString).deletingPathExtension, maxLength: 40) }
            ?? sanitize((source.lastPathComponent as NSString).deletingPathExtension, maxLength: 40)
            ?? fallbackMediaName(for: typeIdentifier)
        let target = uniqueChildURL(name: stem, ext: ext, directory: directory)
        let fm = FileManager.default
        if (try? fm.moveItem(at: source, to: target)) != nil { return target }
        if (try? fm.copyItem(at: source, to: target)) != nil { return target }
        return nil
    }

    /// 媒体载荷的兜底名（对应文本侧的「文本片段」/「链接」）
    static func fallbackMediaName(for typeIdentifier: String) -> String {
        UTType(typeIdentifier)?.conforms(to: .image) == true ? "图片" : "文件"
    }

    // MARK: 剪贴板图像

    /// 剪贴板图像数据 → 收件箱 .tiff / .png 文件（浏览器 / 预览「拷贝图像」）
    @discardableResult
    static func materialize(imageData: Data, ext: String, directory: URL = directory) -> URL? {
        guard !imageData.isEmpty else { return nil }
        let target = uniqueChildURL(name: "图片", ext: ext, directory: directory)
        do {
            try imageData.write(to: target, options: .atomic)
            return target
        } catch {
            return nil
        }
    }
}
