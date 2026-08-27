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

    /// 剪贴板里的纯文本：优先标准 string 类型；富文本（RTF/RTFD）转纯文本
    static func text(from pasteboard: NSPasteboard) -> String? {
        guard let types = pasteboard.types else { return nil }
        if types.contains(.string), let raw = pasteboard.string(forType: .string) {
            return nonEmptyTrimmed(raw)
        }
        // 从 Word / 浏览器等拷贝的富文本：没有 string 表示时，从 RTF 数据提取纯文本
        let richType = types.first { $0 == .rtf || $0 == .rtfd }
        guard let richType, let data = pasteboard.data(forType: richType) else { return nil }
        let documentType: NSAttributedString.DocumentType = richType == .rtfd ? .rtfd : .rtf
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: documentType],
            documentAttributes: nil
        ) else { return nil }
        return nonEmptyTrimmed(attributed.string)
    }

    private static func nonEmptyTrimmed(_ raw: String) -> String? {
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
