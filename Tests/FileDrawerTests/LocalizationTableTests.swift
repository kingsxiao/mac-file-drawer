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
}
