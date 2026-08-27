import AppKit
import AppIntents
import Foundation

// MARK: - 快捷指令（Shortcuts）集成：App Intents
//
// 三个动作直接在「快捷指令」App 里可用（也支持 Siri 短语）：
//   · 放入文件抽屉 —— 把前序动作输出的文件放进抽屉（可指定分组，不存在则创建）
//   · 读取抽屉条目 —— 把抽屉（或指定分组）的文件作为输出交给后续动作
//   · 展开抽屉 —— 展开 / 收起 / 切换
// 与 filedrawer:// URL Scheme 共用 DrawerCommands，行为永远一致。

// MARK: 放入抽屉

struct AddFilesToDrawerIntent: AppIntent {
    static let title: LocalizedStringResource = "放入文件抽屉"
    static let description = IntentDescription("把文件放进文件抽屉的指定分组（不指定则为当前分组），可配合快捷指令的前序输出使用。")

    @Parameter(title: "文件")
    var files: [IntentFile]

    @Parameter(title: "分组（可选，不存在则创建）")
    var group: String?

    static var parameterSummary: some ParameterSummary {
        Summary("把\(\.$files)放入\(\.$group)分组")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let paths = files.compactMap(\.fileURL).map(\.path)
        let result = DrawerCommands.add(paths: paths, group: group)
        return .result(value: result.added)
    }
}

// MARK: 读取抽屉

struct ListDrawerItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "读取抽屉条目"
    static let description = IntentDescription("把抽屉（或指定分组）里的文件作为输出，交给快捷指令的后续动作处理。")

    @Parameter(title: "分组（可选，默认当前分组）")
    var group: String?

    @Parameter(title: "最多返回", default: 50)
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("读取\(\.$group)分组，最多\(\.$limit)个")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let urls = DrawerCommands.list(group: group, limit: limit)
        return .result(value: urls.map { IntentFile(fileURL: $0) })
    }
}

// MARK: 展开 / 收起

/// 展开命令（意图参数枚举）
enum DrawerExpansionCommand: String, AppEnum {
    case toggle
    case expand
    case collapse

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "抽屉动作"
    static let caseDisplayRepresentations: [DrawerExpansionCommand: DisplayRepresentation] = [
        .toggle: "展开 ↔ 收起",
        .expand: "展开",
        .collapse: "收起",
    ]
}

struct SetDrawerExpansionIntent: AppIntent {
    static let title: LocalizedStringResource = "展开文件抽屉"
    static let description = IntentDescription("展开、收起或在两态间切换文件抽屉。")

    @Parameter(title: "动作", default: .toggle)
    var command: DrawerExpansionCommand

    @MainActor
    func perform() async throws -> some IntentResult {
        switch command {
        case .toggle: DrawerCommands.setExpansion(expand: nil)
        case .expand: DrawerCommands.setExpansion(expand: true)
        case .collapse: DrawerCommands.setExpansion(expand: false)
        }
        return .result()
    }
}

// MARK: App Shortcuts（快捷指令 App 里的入口短语）

struct FileDrawerShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddFilesToDrawerIntent(),
            phrases: ["把文件放入\(.applicationName)的抽屉", "放入\(.applicationName)抽屉"],
            shortTitle: "放入抽屉",
            systemImageName: "tray.full"
        )
        AppShortcut(
            intent: ListDrawerItemsIntent(),
            phrases: ["读取\(.applicationName)的抽屉", "读取\(.applicationName)抽屉条目"],
            shortTitle: "读取抽屉",
            systemImageName: "tray.and.arrow.down"
        )
        AppShortcut(
            intent: SetDrawerExpansionIntent(),
            phrases: ["展开\(.applicationName)的抽屉", "收起\(.applicationName)抽屉"],
            shortTitle: "展开抽屉",
            systemImageName: "sidebar.trailing"
        )
    }
}
