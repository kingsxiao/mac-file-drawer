import Foundation

// MARK: - 本地化层：中英文界面切换
//
// 基准语言是中文：key 即中文原文，zh-Hans 无需翻译表（未命中回退 key）。
// 英文放在 Resources/en.lproj/Localizable.strings，按需增量迁移——
// 没进表的字符串自动显示中文，永远不会因缺翻译而变成 key 乱码。

enum L10n {
    /// 当前生效的 bundle：语言覆盖（zh-Hans / en）或模块默认（跟随系统）
    private static var overrideBundle: Bundle?

    /// 设置语言；nil = 跟随系统。返回是否真的变化。
    @discardableResult
    static func setLanguage(_ code: String?) -> Bool {
        let next: Bundle?
        if let code, !code.isEmpty,
           let path = Bundle.module.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            next = bundle
        } else {
            next = nil
        }
        guard next !== overrideBundle else { return false }
        overrideBundle = next
        return true
    }

    /// 当前是否输出英文（覆盖为 en，或跟随系统且系统回退命中英文表）
    static var isEnglish: Bool {
        if let overrideBundle {
            return overrideBundle.preferredLocalizations.first?.hasPrefix("en") == true
        }
        return systemEnglishFallback != nil
    }

    /// 翻译入口：覆盖 bundle 命中用之，否则回退中文原文
    static func t(_ key: String) -> String {
        guard let bundle = overrideBundle ?? systemEnglishFallback else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// 带格式参数的翻译（key 里用 %@ / %d 占位）
    static func tf(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    /// 跟随系统且系统是英文系时启用英文表（系统是中文/其他则回退中文 key）。
    /// 测试进程固定回退中文：断言里大量中文文案，不能随 CI 机器语言漂移。
    private static var systemEnglishFallback: Bundle? {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return nil
        }
        let preferred = Locale.preferredLanguages.first ?? ""
        guard preferred.hasPrefix("en") else { return nil }
        if let path = Bundle.module.path(forResource: "en", ofType: "lproj") {
            return Bundle(path: path)
        }
        return nil
    }
}
