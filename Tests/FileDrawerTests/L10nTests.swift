import XCTest
@testable import FileDrawer

/// 本地化层：回退、覆盖、格式化
final class L10nTests: XCTestCase {

    override func tearDownWithError() throws {
        L10n.setLanguage(nil)
    }

    /// 未翻译的 key 回退中文原文（增量迁移安全）
    func testMissingKeyFallsBackToChinese() {
        L10n.setLanguage("en")
        XCTAssertEqual(L10n.t("一条根本不存在的文案"), "一条根本不存在的文案")
    }

    /// 英文覆盖：key（中文）→ 英文值
    func testEnglishOverrideTranslates() {
        L10n.setLanguage("en")
        XCTAssertEqual(L10n.t("文件抽屉"), "File Drawer")
        XCTAssertEqual(L10n.t("把文件放进来"), "Drop Files Here")
    }

    /// 格式化翻译：%@ / %d 占位
    func testFormattedTranslation() {
        L10n.setLanguage("en")
        XCTAssertEqual(L10n.tf("已选 %d", 3), "3 Selected")
        XCTAssertEqual(L10n.tf("已移除「%@」", "a.txt"), "Removed “a.txt”")
    }

    /// 中文覆盖：显式 zh-Hans 下未翻译 key 也回退中文（zh 表为空）
    func testChineseOverrideUsesChineseKeys() {
        L10n.setLanguage("zh-Hans")
        XCTAssertEqual(L10n.t("文件抽屉"), "文件抽屉")
    }

    /// setLanguage 返回是否变化；nil 清除覆盖
    func testSetLanguageChangeReporting() {
        XCTAssertTrue(L10n.setLanguage("en"))
        XCTAssertFalse(L10n.setLanguage("en"), "重复设置同一语言不算变化")
        XCTAssertTrue(L10n.setLanguage(nil), "清除覆盖算变化")
        XCTAssertEqual(L10n.t("文件抽屉"), "文件抽屉")
    }

    /// 语言设置持久化
    func testLanguageSettingPersistence() {
        let suite = "FileDrawerTests.L10n.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        MainActor.assumeIsolated {
            let settings = AppSettings(defaults: defaults)
            XCTAssertEqual(settings.language, .system, "默认跟随系统")
            settings.language = .english
            XCTAssertEqual(AppSettings(defaults: defaults).language, .english, "语言选择应持久化")
        }
    }

    /// isEnglish 指示与语言覆盖一致
    func testIsEnglishIndicator() {
        L10n.setLanguage("en")
        XCTAssertTrue(L10n.isEnglish)
        L10n.setLanguage("zh-Hans")
        XCTAssertFalse(L10n.isEnglish, "显式中文不是英文")
        L10n.setLanguage(nil)
        // 测试进程固定中文回退（见 L10n.systemEnglishFallback 的测试守卫）
        XCTAssertFalse(L10n.isEnglish)
    }

    /// 相对时间按界面语言格式化：英文含 ago，中文含 前
    func testRelativeAddedFollowsLanguage() {
        let past = Date(timeIntervalSinceNow: -3 * 3600)
        L10n.setLanguage("en")
        XCTAssertTrue(ShelfItem.relativeAdded(past).contains("ago"), "英文模式应为 ago 形式")
        L10n.setLanguage("zh-Hans")
        XCTAssertTrue(ShelfItem.relativeAdded(past).contains("前"), "中文模式应为「前」形式")
    }
}
