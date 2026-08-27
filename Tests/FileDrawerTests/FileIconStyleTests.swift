import XCTest
import AppKit
@testable import FileDrawer

/// 文件类型样式目录的行为契约：
/// 1) 每个 SF Symbol 名在当前系统真实存在（图标必须全部适配）；
/// 2) 覆盖面广（扩展名 + 特殊文件名 + 文件夹 bundle）；
/// 3) 同族不同语言/格式各有专属配色与角标；
/// 4) 未收录扩展名按 UTType 一致性兜底。
final class FileIconStyleTests: XCTestCase {

    private func kind(_ path: String) -> FileKind {
        FileKind(url: URL(fileURLWithPath: path))
    }

    // MARK: - 图标适配性

    /// 目录里出现过的每一个符号都必须能被系统解析——
    /// 任何一个拼错或超出系统版本的符号都会在这里暴露。
    func testAllCatalogSymbolsResolveOnThisOS() {
        let all = FileTypeCatalog.allStyles
        XCTAssertGreaterThan(all.count, 200, "目录覆盖面应足够广")

        var missing = [String]()
        for (label, style) in all {
            if NSImage(systemSymbolName: style.symbolName, accessibilityDescription: nil) == nil {
                missing.append("\(label) → \(style.symbolName)")
            }
        }
        XCTAssertTrue(missing.isEmpty, "以下符号在当前系统不存在：\n\(missing.joined(separator: "\n"))")
    }

    // MARK: - 代码语言逐个适配

    func testCodeLanguagesEachGetTailoredStyle() {
        XCTAssertEqual(kind("/tmp/a.swift").style.symbolName, "bird.fill")

        let ts = kind("/tmp/a.ts").style
        XCTAssertEqual(ts.badge, "TS")
        let py = kind("/tmp/a.py").style
        XCTAssertEqual(py.badge, "PY")
        XCTAssertNotEqual(ts, py, "TypeScript 与 Python 应有不同的配色/角标")

        // 同为斜杠符号的家族也各有品牌色
        let go = kind("/tmp/a.go").style
        let rs = kind("/tmp/a.rs").style
        XCTAssertEqual(go.symbolName, FileTypeCatalog.slashSymbol)
        XCTAssertEqual(rs.symbolName, FileTypeCatalog.slashSymbol)
        XCTAssertNotEqual(go.color, rs.color)

        // 脚本族用终端符号
        XCTAssertEqual(kind("/tmp/deploy.sh").style.symbolName, "terminal.fill")
    }

    // MARK: - 大类之间视觉可区分

    func testMajorFamiliesVisuallyDistinct() {
        let paths = [
            "/tmp/a.pdf", "/tmp/a.docx", "/tmp/a.xlsx", "/tmp/a.pptx",
            "/tmp/a.png", "/tmp/a.mp4", "/tmp/a.mp3", "/tmp/a.zip",
            "/tmp/a.ttf", "/tmp/a.fig",
        ]
        let styles = paths.map { kind($0).style }
        XCTAssertEqual(Set(styles.map(\.symbolName)).count, styles.count, "各大类应使用互不相同的符号")
    }

    // MARK: - 粗分类（排序 / 缩略图策略）

    func testVariantMappingForSortingAndThumbnails() {
        XCTAssertEqual(kind("/tmp/a.xlsx").variant, .spreadsheet)
        XCTAssertEqual(kind("/tmp/a.pptx").variant, .presentation)
        XCTAssertEqual(kind("/tmp/a.ttf").variant, .font)
        XCTAssertEqual(kind("/tmp/a.fig").variant, .design)
        XCTAssertEqual(kind("/tmp/a.dmg").variant, .archive)
        XCTAssertEqual(kind("/tmp/a.docx").variant, .document)

        XCTAssertTrue(kind("/tmp/a.png").producesThumbnail, "图片必须支持缩略图")
        XCTAssertTrue(kind("/tmp/a.mov").producesThumbnail)
        XCTAssertTrue(kind("/tmp/a.pdf").producesThumbnail)
        XCTAssertFalse(kind("/tmp/a.docx").producesThumbnail)
    }

    // MARK: - 兜底

    func testUnknownExtensionFallsBackToNeutralDoc() {
        let unknown = kind("/tmp/a.zzzq")
        XCTAssertEqual(unknown.variant, .other)
        XCTAssertEqual(unknown.style, FileTypeCatalog.otherFallback)
    }

    func testCodeFamilyBadgesOnlyWithinReadableLength() {
        // 过长的扩展名（gemspec）不显示角标；常规的显示大写扩展名
        XCTAssertNil(kind("/tmp/lib.gemspec").style.badge)
        XCTAssertEqual(kind("/tmp/lib.rb").style.badge, "RB")
    }

    // MARK: - 文件夹 / bundle

    func testFoldersAndBundlesGetDistinctStyles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("文件夹样本\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(FileKind(url: dir).style.symbolName, "folder.fill")

        let app = dir.appendingPathComponent("小工具.app", isDirectory: true)
        let appKind = FileKind(url: app)
        XCTAssertEqual(appKind.style.symbolName, "app.fill")
        XCTAssertEqual(appKind.variant, .folder, "bundle 目录仍归入文件夹分组")

        XCTAssertEqual(FileKind(url: dir.appendingPathComponent("P.xcodeproj", isDirectory: true)).style.symbolName, "hammer.fill")
    }

    // MARK: - 特殊文件名

    func testSpecialFileNamesRecognized() {
        XCTAssertEqual(kind("/proj/Dockerfile").style.symbolName, "shippingbox.fill")
        XCTAssertEqual(kind("/proj/Makefile").style.symbolName, "hammer.fill")
        XCTAssertEqual(kind("/proj/.gitignore").style.symbolName, "arrow.triangle.branch")
        XCTAssertEqual(kind("/proj/Gemfile").style.symbolName, "diamond.fill")
        // 同名但走扩展名优先级的组合文件
        XCTAssertEqual(kind("/proj/docker-compose.yml").style.symbolName, "shippingbox.fill")
    }

    // MARK: - 覆盖广度

    func testCatalogBreadth() {
        XCTAssertGreaterThanOrEqual(FileTypeCatalog.entries.count, 200, "扩展名目录应覆盖 200+ 格式")
        XCTAssertGreaterThanOrEqual(FileTypeCatalog.fileNameEntries.count, 10, "特殊文件名目录应覆盖常见工程文件")
    }
}
