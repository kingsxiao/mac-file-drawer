import SwiftUI
import UniformTypeIdentifiers

// MARK: - 文件类型视觉样式：符号 + 主题色 + 可选角标
// 设计语言：低饱和同系渐变底 + 同系色符号 + 扩展名角标；
// 明暗模式共用一套色值，靠透明度与材质融合（仿系统标签 / 提醒事项列表色）。

struct FileIconStyle: Equatable {
    let symbolName: String
    let color: Color
    /// 角标文字（多为扩展名缩写，区分同族语言/格式）；nil 不显示
    let badge: String?

    init(symbolName: String, hex: UInt32, badge: String? = nil) {
        self.symbolName = symbolName
        self.color = Color(hex: hex)
        self.badge = badge
    }
}

// MARK: - FileKind：URL →（粗分类 Variant + 精细样式 style）

struct FileKind: Equatable {
    /// 粗分类：排序分组与缩略图策略使用
    enum Variant: Equatable, Hashable {
        case folder, pdf, document, spreadsheet, presentation, image, video, audio, archive, code, design, font, other
    }

    let variant: Variant
    let style: FileIconStyle

    init(url: URL) {
        let ext = url.pathExtension.lowercased()

        // 文件夹与各种 bundle（app / framework / xcodeproj …）
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true ||
            url.hasDirectoryPath {
            variant = .folder
            style = FileTypeCatalog.folderStyle(ext: ext)
            return
        }

        // 目录命中：先按特殊文件名（Dockerfile 等），再按扩展名
        if let entry = FileTypeCatalog.entry(fileName: url.lastPathComponent.lowercased(), ext: ext) {
            variant = entry.variant
            style = entry.style
            return
        }

        // 未收录的扩展名：按 UTType 一致性兜底归类
        let t = UTType(filenameExtension: ext) ?? .data
        if t.conforms(to: .image) {
            (variant, style) = (.image, FileTypeCatalog.imageFallback)
        } else if t.conforms(to: .movie) || t.conforms(to: .video) {
            (variant, style) = (.video, FileTypeCatalog.videoFallback)
        } else if t.conforms(to: .audio) {
            (variant, style) = (.audio, FileTypeCatalog.audioFallback)
        } else if t.conforms(to: .pdf) {
            (variant, style) = (.pdf, FileTypeCatalog.pdfFallback)
        } else if t.conforms(to: .zip) {
            (variant, style) = (.archive, FileTypeCatalog.archiveFallback)
        } else if t.conforms(to: .sourceCode) {
            (variant, style) = (.code, FileIconStyle(
                symbolName: FileTypeCatalog.slashSymbol,
                hex: 0x5B6EE1,
                badge: FileTypeCatalog.autoBadge(ext)
            ))
        } else if t.conforms(to: .text) {
            (variant, style) = (.document, FileTypeCatalog.documentFallback)
        } else {
            (variant, style) = (.other, FileTypeCatalog.otherFallback)
        }
    }

    /// 图片 / 视频（AVFoundation 抽帧）/ PDF（首页）可生成真实缩略图
    var producesThumbnail: Bool {
        switch variant {
        case .image, .video, .pdf: return true
        default: return false
        }
    }
}

// MARK: - 类型目录：扩展名 / 特殊文件名 → 样式

enum FileTypeCatalog {
    struct Entry: Equatable {
        let variant: FileKind.Variant
        let style: FileIconStyle
    }

    static let slashSymbol = "chevron.left.forwardslash.chevron.right"

    /// 扩展名自动角标：2–5 个字符才显示（太长的小瓷片里放不下）
    static func autoBadge(_ ext: String) -> String? {
        let upper = ext.uppercased()
        return (2...5).contains(upper.count) ? upper : nil
    }

    private static func entry(
        _ variant: FileKind.Variant,
        _ symbol: String,
        _ hex: UInt32,
        badge: String? = nil
    ) -> Entry {
        Entry(variant: variant, style: FileIconStyle(symbolName: symbol, hex: hex, badge: badge))
    }

    /// 代码族：共用斜杠符号（可换），角标取扩展名
    private static func code(_ hex: UInt32, ext: String, symbol: String = slashSymbol) -> Entry {
        entry(.code, symbol, hex, badge: autoBadge(ext))
    }

    private static func family(_ exts: [String], _ e: Entry) -> [(String, Entry)] {
        exts.map { ($0, e) }
    }

    /// 同一族的多个扩展名，各自带自己的角标
    private static func codes(_ hex: UInt32, _ exts: [String], symbol: String = slashSymbol) -> [(String, Entry)] {
        exts.map { ($0, code(hex, ext: $0, symbol: symbol)) }
    }

    // MARK: 扩展名目录

    static let entries: [String: Entry] = Dictionary(uniqueKeysWithValues: [
        // —— 文档
        family(["pdf"], entry(.pdf, "doc.richtext.fill", 0xE0455F)),
        family(["doc", "docx", "docm", "odt", "rtf"], entry(.document, "doc.text.fill", 0x2B579A)),
        family(["pages"], entry(.document, "doc.text.fill", 0xE0862E)),
        family(["txt", "text", "log", "err"], entry(.document, "doc.plaintext.fill", 0x6E7B8A)),
        family(["epub", "mobi", "azw", "azw3"], entry(.document, "book.fill", 0xE0871E)),

        // —— 表格 / 演示
        family(["xls", "xlsx", "xlsm", "xlsb", "ods", "csv", "tsv", "numbers"],
               entry(.spreadsheet, "tablecells.fill", 0x1F8A4C)),
        family(["ppt", "pptx", "pptm", "pps", "ppsx", "odp"],
               entry(.presentation, "rectangle.on.rectangle.fill", 0xC7502B)),
        family(["key"], entry(.presentation, "rectangle.on.rectangle.fill", 0x3E8EDE)),

        // —— 图片
        family(["jpg", "jpeg", "jpe", "png", "apng", "gif", "webp", "bmp", "tiff", "tif",
                "heic", "heif", "avif", "jxl", "jfif", "xpm", "ppm", "pnm", "ico", "icns"],
               entry(.image, "photo.fill", 0x2FA252)),
        family(["cr2", "crw", "nef", "arw", "dng", "raf", "orf", "rw2", "srw", "pef", "ptx", "3fr", "fff", "iiq"],
               entry(.image, "camera.aperture", 0x27ABA5)),
        family(["svg"], entry(.image, "paintbrush.pointed.fill", 0x8E5BD8)),

        // —— 视频 / 音频
        family(["mov", "qt", "mp4", "m4v", "mp2", "m2v", "mpg", "mpeg", "mpe", "mkv", "webm",
                "avi", "flv", "f4v", "wmv", "3gp", "3g2", "m2ts", "rm", "rmvb", "vob", "ogv"],
               entry(.video, "film.fill", 0x7B52CC)),
        family(["mp3", "wav", "aac", "m4a", "m4b", "flac", "alac", "ogg", "oga", "opus",
                "aiff", "aif", "aifc", "wma", "ape", "wv", "tta", "amr", "caf"],
               entry(.audio, "waveform", 0xC93A70)),
        family(["mid", "midi", "kar", "rmi"], entry(.audio, "music.note", 0xBF4A82)),

        // —— 压缩包 / 磁盘映像
        family(["zip", "zipx", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz",
                "lz", "lz4", "lzma", "zst", "cab", "arj", "lha"],
               entry(.archive, "doc.zipper", 0xA76B1F)),
        family(["dmg", "iso", "img", "cdr", "sparseimage", "sparsebundle"],
               entry(.archive, "opticaldiscdrive", 0x98A0A8)),

        // —— 字体
        family(["ttf", "otf", "ttc", "woff", "woff2", "eot"],
               entry(.font, "textformat", 0x6C5CE7)),

        // —— 代码：逐语言品牌色 + 扩展名角标
        family(["swift"], entry(.code, "bird.fill", 0xF05138)),
        codes(0xB08300, ["js", "mjs", "cjs"]),
        codes(0x3178C6, ["ts", "mts", "cts", "tsx"]),
        codes(0x2FA8C9, ["jsx"]),
        codes(0x3572A5, ["py", "pyw", "pyi", "pyx"]),
        codes(0xA22B38, ["rb", "erb", "rake", "gemspec"]),
        codes(0x0A97B0, ["go"]),
        codes(0xB7472A, ["rs"]),
        codes(0xB07219, ["java"]),
        codes(0x8B5CF6, ["kt", "kts", "ktm"]),
        codes(0xC22D40, ["scala", "sc", "sbt"]),
        codes(0x556FA8, ["c"]),
        codes(0xC93B6B, ["cpp", "cc", "cxx", "hpp", "hxx", "hh"]),
        codes(0x5B6EE1, ["h"]),
        codes(0x3E7BD6, ["m"]),
        codes(0x7B52CC, ["mm"]),
        codes(0x2E8B44, ["cs"]),
        codes(0x7377AD, ["php", "phtml"]),
        codes(0x0175C2, ["dart"]),
        codes(0x5C5CD6, ["lua"]),
        codes(0x366FA0, ["pl", "pm", "raku", "rakumod"]),
        codes(0x198CE7, ["r"]),
        codes(0x7A5CB8, ["jl"]),
        codes(0x5E5086, ["hs", "lhs"]),
        codes(0x6E4A7E, ["ex", "exs", "eex", "leex", "heex"]),
        codes(0x2E9E6B, ["vue"]),
        codes(0xD9442A, ["svelte"]),
        codes(0xA04C4C, ["asm", "s"]),
        codes(0x4E9A51, ["sh", "bash", "zsh", "fish", "ksh"], symbol: "terminal.fill"),
        codes(0x4A6B8A, ["bat", "cmd", "ps1", "psm1"], symbol: "terminal.fill"),
        family(["md", "markdown", "mdx", "rmd"], entry(.code, "character.textbox", 0x8E6FD8, badge: "MD")),
        family(["html", "htm", "xhtml"], entry(.code, "globe.fill", 0xCB4B22)),
        family(["css"], entry(.code, "paintbrush.fill", 0x663DA6)),
        codes(0xC76495, ["scss", "sass", "less", "styl"], symbol: "paintbrush.fill"),
        codes(0xC0327E, ["graphql", "gql"], symbol: "curlybraces.square.fill"),
        family(["json", "jsonc", "geojson", "topojson"],
               entry(.code, "curlybraces.square.fill", 0xC7A53C)),
        codes(0xB04A45, ["yml", "yaml"], symbol: "gearshape.fill"),
        codes(0x7A8794, ["toml", "ini", "conf", "cfg", "config", "rc"], symbol: "gearshape.fill"),
        family(["plist"], entry(.code, "doc.badge.gearshape", 0x7A8794)),
        family(["env"], entry(.code, "leaf.fill", 0x4E9A51, badge: "ENV")),
        family(["lock"], entry(.code, "lock.fill", 0x8A8F98)),
        family(["tex", "latex", "sty"], entry(.code, "function", 0x3D6BD6, badge: "TEX")),
        family(["sql"], entry(.code, "cylinder.split.1x2.fill", 0xC8860A, badge: "SQL")),
        family(["ipynb"], entry(.code, "square.grid.3x3.fill", 0xD97706, badge: "NB")),

        // —— 设计 / 3D
        family(["psd", "psb"], entry(.design, "paintpalette.fill", 0x2E86D6)),
        family(["ai"], entry(.design, "paintbrush.pointed.fill", 0xD98218)),
        family(["sketch"], entry(.design, "paintpalette.fill", 0xC79100)),
        family(["fig"], entry(.design, "paintpalette.fill", 0x8E4DE0)),
        family(["xd"], entry(.design, "paintpalette.fill", 0xC757C7)),
        family(["afdesign", "afphoto"], entry(.design, "paintpalette.fill", 0x9A6BC8)),
        family(["eps"], entry(.design, "paintbrush.pointed.fill", 0xC79A2E)),
        codes(0xE8862E, ["obj", "stl", "fbx", "3ds", "dae", "glb", "gltf", "usdz", "usda", "usd", "ply", "blend"],
              symbol: "cube.transparent.fill"),

        // —— 证书 / 数据 / 联系人 / 日历 / 字幕 / 其他
        codes(0x2FA3B0, ["pem", "cer", "crt", "p12", "pfx", "pub", "jks"], symbol: "lock.shield.fill"),
        family(["db", "sqlite", "sqlite3", "db3", "mdb", "accdb"],
               entry(.other, "cylinder.split.1x2.fill", 0xB07C2A)),
        family(["vcf", "vcard"], entry(.other, "person.crop.rectangle.fill", 0x2FA252)),
        family(["ics", "ifb"], entry(.other, "calendar", 0xD03A3A)),
        codes(0x5B7FA6, ["srt", "ass", "ssa", "vtt", "sub"], symbol: "captions.bubble.fill"),
        family(["torrent"], entry(.other, "arrow.down.circle", 0x7A8794)),
        family(["exe", "msi"], entry(.other, "pc", 0x6E7680)),
        family(["apk", "aab"], entry(.other, "app.fill", 0x4E9A51)),
        // 拖入链接物化成的网页快捷方式
        family(["webloc", "url"], entry(.other, "link", 0x2E86D6, badge: "URL")),
    ].flatMap { $0 })

    // MARK: 特殊文件名（无扩展名或需优先于扩展名识别）

    static let fileNameEntries: [String: Entry] = Dictionary(uniqueKeysWithValues: [
        family(["makefile", "gnumakefile"], entry(.code, "hammer.fill", 0x6E7680)),
        family(["dockerfile"], entry(.code, "shippingbox.fill", 0x2E7CD6)),
        family(["docker-compose.yml", "docker-compose.yaml"], entry(.code, "shippingbox.fill", 0x2E7CD6)),
        family(["cmakelists.txt"], entry(.code, "hammer.fill", 0x6E7680)),
        family(["license", "licence", "copying", "notice"], entry(.document, "checkmark.seal.fill", 0x6E7B8A)),
        family(["gemfile", "rakefile"], entry(.code, "diamond.fill", 0xA22B38)),
        family(["podfile"], entry(.code, "shippingbox.fill", 0xD9444E)),
        family([".gitignore", ".gitattributes", ".gitmodules"], entry(.code, "arrow.triangle.branch", 0xF05138)),
        family([".env"], entry(.code, "leaf.fill", 0x4E9A51, badge: "ENV")),
        family([".dockerignore"], entry(.code, "shippingbox.fill", 0x7A8794)),
    ].flatMap { $0 })

    static func entry(fileName: String, ext: String) -> Entry? {
        fileNameEntries[fileName] ?? entries[ext]
    }

    // MARK: 文件夹 / bundle

    static func folderStyle(ext: String) -> FileIconStyle {
        switch ext {
        case "app":            return FileIconStyle(symbolName: "app.fill", hex: 0x7D5BE8)
        case "framework":      return FileIconStyle(symbolName: "cube.fill", hex: 0x5E5CE6)
        case "xcodeproj", "xcworkspace":
            return FileIconStyle(symbolName: "hammer.fill", hex: 0x4A8ED8)
        case "playground":     return FileIconStyle(symbolName: "square.stack.3d.up.fill", hex: 0xF05138)
        default:               return FileIconStyle(symbolName: "folder.fill", hex: 0x3D9BE8)
        }
    }

    // MARK: 各大类兜底样式（供 UTType 一致性路径使用）

    static let imageFallback = FileIconStyle(symbolName: "photo.fill", hex: 0x2FA252)
    static let videoFallback = FileIconStyle(symbolName: "film.fill", hex: 0x7B52CC)
    static let audioFallback = FileIconStyle(symbolName: "waveform", hex: 0xC93A70)
    static let pdfFallback = FileIconStyle(symbolName: "doc.richtext.fill", hex: 0xE0455F)
    static let archiveFallback = FileIconStyle(symbolName: "doc.zipper", hex: 0xA76B1F)
    static let documentFallback = FileIconStyle(symbolName: "doc.plaintext.fill", hex: 0x6E7B8A)
    static let otherFallback = FileIconStyle(symbolName: "doc.fill", hex: 0x83898F)

    /// 测试用：目录里出现过的全部样式（含文件夹与兜底）
    static var allStyles: [(String, FileIconStyle)] {
        entries.map { ("ext:\($0.key)", $0.value.style) }
            + fileNameEntries.map { ("file:\($0.key)", $0.value.style) }
            + [
                ("folder:app", folderStyle(ext: "app")),
                ("folder:framework", folderStyle(ext: "framework")),
                ("folder:xcodeproj", folderStyle(ext: "xcodeproj")),
                ("folder:playground", folderStyle(ext: "playground")),
                ("folder:default", folderStyle(ext: "")),
                ("fallback:image", imageFallback),
                ("fallback:video", videoFallback),
                ("fallback:audio", audioFallback),
                ("fallback:pdf", pdfFallback),
                ("fallback:archive", archiveFallback),
                ("fallback:document", documentFallback),
                ("fallback:other", otherFallback),
            ]
    }
}

// MARK: - 十六进制颜色

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
