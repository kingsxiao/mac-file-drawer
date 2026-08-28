import Foundation

// MARK: - 本地化层：中英文界面切换
//
// 基准语言是中文：key 即中文原文，zh-Hans 无需翻译表（未命中回退 key）。
// 英文放在 Resources/en.lproj/Localizable.strings，按需增量迁移——
// 没进表的字符串自动显示中文，永远不会因缺翻译而变成 key 乱码。

enum L10n {
    /// 当前生效的 bundle：语言覆盖（zh-Hans / en）或模块默认（跟随系统）
    private static var overrideBundle: Bundle?
    /// 与 overrideBundle 同步记录的语言代码。isEnglish 不能用 preferredLocalizations 判断——
    /// CF 对裸 lproj 目录 Bundle 解析不出可用本地化，该查询会漂移到用户首选语言（实测返回 ["en"]）。
    private static var overrideLanguage: String?

    /// 设置语言；nil = 跟随系统。返回是否真的变化。
    @discardableResult
    static func setLanguage(_ code: String?) -> Bool {
        let next: Bundle?
        let nextLanguage: String?
        if let code, !code.isEmpty, let bundle = lprojBundle(for: code) {
            next = bundle
            nextLanguage = code
        } else {
            next = nil
            nextLanguage = nil
        }
        guard next !== overrideBundle || nextLanguage != overrideLanguage else { return false }
        overrideBundle = next
        overrideLanguage = nextLanguage
        return true
    }

    /// 显式语言 → 对应 lproj 的 Bundle。
    /// 不走 `path(forResource:ofType:)`——它会按进程首选语言做本地化匹配：
    /// 英文系统上请求 zh-Hans.lproj 会被解析到 en.lproj（CI 上显式切中文切不动正是这个）。
    /// 改为直接枚举 bundle 目录做大小写无关匹配（SwiftPM 产物里目录名可能小写成 zh-hans.lproj）。
    private static func lprojBundle(for code: String) -> Bundle? {
        guard let baseURL = Bundle.module.resourceURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: baseURL, includingPropertiesForKeys: nil)
        else { return nil }
        guard let dir = entries.first(where: {
            $0.pathExtension == "lproj"
                && $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(code) == .orderedSame
        }) else { return nil }
        return Bundle(url: dir)
    }

    /// 当前是否输出英文（覆盖为 en，或跟随系统且系统回退命中英文表）
    static var isEnglish: Bool {
        if let overrideLanguage {
            return overrideLanguage.hasPrefix("en")
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
        if isTestProcess { return nil }
        let preferred = Locale.preferredLanguages.first ?? ""
        guard preferred.hasPrefix("en") else { return nil }
        return lprojBundle(for: "en")
    }

    /// 测试进程判定：XCTestConfigurationFilePath 在部分 swift test 形态下缺失
    ///（英文 CI runner 上曾因此漏开英文回退），补「XCTest 类是否已加载」兜底；
    /// App 进程不链接 XCTest，此查询恒为 nil。
    private static var isTestProcess: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
