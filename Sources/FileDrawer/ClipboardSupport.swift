import AppKit
import UniformTypeIdentifiers

// MARK: - 剪贴板集成：抽屉 ⇄ 系统剪贴板
//
// ⌘C / 右键「拷贝文件」把条目文件写进剪贴板（与访达拷贝同构，任何应用可粘贴）；
// ⌘V /「粘贴到抽屉」接收访达拷贝的文件，或把剪贴板里的文本 / 链接物化成收件箱条目。

enum ClipboardSupport {

    /// 把条目文件以「访达拷贝」的语义写入剪贴板
    @MainActor
    static func copyFile(_ item: ShelfItem) {
        copyFiles([item])
    }

    /// 批量拷贝（多选 ⌘C）：一次写入多个文件，目标端按访达多选拷贝接收
    @MainActor
    static func copyFiles(_ items: [ShelfItem]) {
        let urls = items.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.url)
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    /// 从任意剪贴板读出文件 URL（只认真实文件，忽略纯字符串）
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls ?? []
    }

    /// 剪贴板里的纯文本（优先富文本转纯文本）
    static func text(from pasteboard: NSPasteboard) -> String? {
        guard let types = pasteboard.types else { return nil }
        guard types.contains(.string) else { return nil }
        guard let raw = pasteboard.string(forType: .string) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 粘贴主入口：文件 → 原样入列；文本 / 链接 → 物化成收件箱条目。返回最终入列的 URL。
    @MainActor
    static func pasteableURLs(
        from pasteboard: NSPasteboard = .general,
        directory: URL = InboxStore.directory
    ) -> [URL] {
        let files = fileURLs(from: pasteboard)
        if !files.isEmpty { return files }

        guard let text = text(from: pasteboard) else { return [] }
        if let link = URL(string: text), ["http", "https"].contains(link.scheme?.lowercased() ?? "") {
            if let materialized = InboxStore.materialize(url: link, directory: directory) { return [materialized] }
        }
        if let materialized = InboxStore.materialize(text: text, directory: directory) { return [materialized] }
        return []
    }
}
