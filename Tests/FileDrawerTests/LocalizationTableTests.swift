import XCTest
@testable import FileDrawer

/// 本地化表完整性：英文表可解析、App Intents 面板相关键齐全
final class LocalizationTableTests: XCTestCase {

    private func englishTable() throws -> [String: String] {
        let bundle = Bundle.module
        let path = try XCTUnwrap(
            bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en"),
            "en.lproj/Localizable.strings 应存在于模块资源里"
        )
        let dictionary = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
        return dictionary
    }

    /// App Intents 面板（动作标题 / 参数名 / 枚举展示）相关键全部有英文值
    func testAppIntentsKeysPresent() throws {
        let table = try englishTable()
        let keys = [
            "放入文件抽屉",
            "读取抽屉条目",
            "展开文件抽屉",
            "把文件放进文件抽屉的指定分组（不指定则为当前分组），可配合快捷指令的前序输出使用。",
            "把抽屉（或指定分组）里的文件作为输出，交给快捷指令的后续动作处理。",
            "展开、收起或在两态间切换文件抽屉。",
            "文件",
            "分组（可选，不存在则创建）",
            "分组（可选，默认当前分组）",
            "最多返回",
            "动作",
            "抽屉动作",
            "展开 ↔ 收起",
            "展开",
            "收起",
        ]
        for key in keys {
            let value = table[key]
            XCTAssertNotNil(value, "英文表缺少键：\(key)")
            XCTAssertNotEqual(value, key, "英文值不应等于中文键：\(key)")
        }
    }

    /// 表内值无残留未翻译占位（值不能是空串）
    func testNoEmptyValues() throws {
        let table = try englishTable()
        for (key, value) in table {
            XCTAssertFalse(value.isEmpty, "键「\(key)」的英文值为空")
        }
    }

    /// 带格式占位符的键：英文值的占位符序列（类型与顺序）必须与中文键一致。
    /// String(format:) 按位置绑定参数——顺序错位会把 %@ 绑到 Int 上（未定义行为/崩溃）。
    func testFormatSpecifierSequencesMatch() throws {
        let table = try englishTable()

        func specifiers(_ s: String) -> [String] {
            // 抽取 %d / %@（忽略 %% 转义）
            var result: [String] = []
            var iterator = s.makeIterator()
            while let ch = iterator.next() {
                guard ch == "%" else { continue }
                if let next = iterator.next() {
                    if next == "%" { continue }
                    if next == "d" || next == "@" { result.append("%\(next)") }
                }
            }
            return result
        }

        var mismatches: [String] = []
        for (key, value) in table where key.contains("%") {
            let expected = specifiers(key)
            let actual = specifiers(value)
            if expected != actual {
                mismatches.append("「\(key)」 key=\(expected) value=\(actual)")
            }
        }
        XCTAssertTrue(
            mismatches.isEmpty,
            "英文值占位符序列与键不一致（String(format:) 按位绑定，错位即崩溃）：\n\(mismatches.joined(separator: "\n"))"
        )
        XCTAssertGreaterThan(
            table.filter { $0.key.contains("%") }.count, 10,
            "带占位符的键应覆盖一定数量，防止空集假绿"
        )
    }

    /// 全量覆盖：扫描 Sources/FileDrawer 全部 Swift 源码，提取 L10n.t / L10n.tf
    /// 调用的字符串字面量 key，断言每个都存在于 en 表（缺失的 key 在英文模式下
    /// 回退中文——用户看到中英混杂）。动态 key（如 L10n.t(language.label)）的
    /// 值本身以字面量出现在定义处，同样被扫描覆盖
    func testAllCodeReferencedKeysHaveTranslations() throws {
        let table = try englishTable()

        // 仓库根 = 测试文件路径上去掉 Tests/FileDrawerTests/<file>
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile.deletingLastPathComponent() // …/Tests/FileDrawerTests
            .deletingLastPathComponent()                    // …/Tests
            .deletingLastPathComponent()                    // 仓库根
        let sourcesDir = repoRoot.appendingPathComponent("Sources/FileDrawer")

        let fm = FileManager.default
        var swiftFiles: [URL] = []
        if let enumerator = fm.enumerator(at: sourcesDir, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                swiftFiles.append(url)
            }
        }
        try XCTSkipIf(swiftFiles.isEmpty, "找不到源码目录（\(sourcesDir.path)），跳过全量扫描")

        // 匹配 L10n.t( 与 L10n.tf( 紧随的字符串字面量（含转义）
        let pattern = #"L10n\.t(?:f)?\(\s*"((?:[^"\\]|\\.)*)""#
        let regex = try NSRegularExpression(pattern: pattern)
        var keys = Set<String>()
        for file in swiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                if let raw = Range(match.range(at: 1), in: source) {
                    // 反转义源码字面量（\n \" \\）得到运行时字符串
                    let literal = source[raw].replacingOccurrences(of: "\\n", with: "\n")
                        .replacingOccurrences(of: "\\\"", with: "\"")
                        .replacingOccurrences(of: "\\\\", with: "\\")
                    keys.insert(literal)
                }
            }
        }
        XCTAssertGreaterThan(keys.count, 200, "扫描应覆盖相当数量的 key，防止空集假绿")

        let missing = keys.filter { table[$0] == nil }.sorted()
        XCTAssertTrue(
            missing.isEmpty,
            "代码引用但英文表缺失的键（英文模式下会回退中文）：\n\(missing.joined(separator: "\n"))"
        )
    }

    /// .strings 文件不允许重复 key：NSDictionary 解析时静默取后值，重复行说明
    /// 表在生长时失控（历史实测 8 组，其中 3 组值冲突实际生效后者、前者成误导）
    func testNoDuplicateKeysInTables() throws {
        for localization in ["en", "zh-Hans"] {
            let bundle = Bundle.module
            let path = try XCTUnwrap(
                bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: localization),
                "\(localization).lproj/Localizable.strings 应存在"
            )
            let text = try String(contentsOfFile: path, encoding: .utf8)

            // 逐行取行首 "key" = 形式的 key（跳过注释行）
            let linePattern = #"^\s*"((?:[^"\\]|\\.)*)"\s*="#
            let lineRegex = try NSRegularExpression(pattern: linePattern, options: [.anchorsMatchLines])
            let range = NSRange(text.startIndex..., in: text)
            var seen: [String: Int] = [:]
            var duplicates: Set<String> = []
            for match in lineRegex.matches(in: text, range: range) {
                if let r = Range(match.range(at: 1), in: text) {
                    let key = String(text[r])
                    if let first = seen[key] {
                        duplicates.insert("「\(key)」（首次第 \(first) 行起重复）")
                    } else {
                        seen[key] = lineNumber(of: match.range.location, in: text)
                    }
                }
            }
            XCTAssertTrue(
                duplicates.isEmpty,
                "\(localization) 表存在重复 key（NSDictionary 静默取后值，前值成误导）：\n\(duplicates.sorted().joined(separator: "\n"))"
            )
        }
    }

    /// 字符偏移 → 1 起行号
    private func lineNumber(of offset: Int, in text: String) -> Int {
        text.prefix(offset).filter { $0 == "\n" }.count + 1
    }
}
