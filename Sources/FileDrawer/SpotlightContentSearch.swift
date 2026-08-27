@preconcurrency import AppKit
@preconcurrency import Foundation

// MARK: - Spotlight 内容搜索
//
// 名称搜索之外，把查询词交给 Spotlight 的 kMDItemTextContent 匹配文件内容，
// 结果与抽屉条目按路径求交后作为「内容命中」并入搜索结果（名称命中在前）。
// 查询有 3 秒超时与 2 字符起搜门槛；仅在设置开启时运行。

@MainActor
final class SpotlightContentSearch {
    static let shared = SpotlightContentSearch()

    /// 元数据查询字符串的转义：去掉引号与反斜杠，防止谓词注入 / 破损
    nonisolated static func escaped(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(of: "*", with: " ")
    }

    /// 是否值得起一次内容搜索：设置开启 + 至少 2 个非空白字符
    nonisolated static func shouldSearch(_ raw: String, enabled: Bool) -> Bool {
        guard enabled else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2
    }

    /// 查询过程状态（只在主队列访问；@unchecked Sendable 仅为通过通知闭包捕获检查）
    private final class QueryBox: @unchecked Sendable {
        let query = NSMetadataQuery()
        var observer: NSObjectProtocol?
    }

    /// 查询全文包含匹配的文件路径集合；超时或 Spotlight 不可用返回空
    func searchPaths(matching raw: String) async -> Set<String> {
        let keyword = Self.escaped(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Set<String>, Never>) in
            let box = QueryBox()
            box.query.predicate = NSPredicate(format: "kMDItemTextContent ==[c] %@", "*\(keyword)*")
            box.query.searchScopes = []
            var finished = false

            box.observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: box.query,
                queue: .main
            ) { _ in
                if let observer = box.observer { NotificationCenter.default.removeObserver(observer) }
                guard !finished else { return }
                finished = true
                box.query.stop()
                var paths = Set<String>()
                for index in 0..<box.query.resultCount {
                    if let item = box.query.result(at: index) as? NSMetadataItem,
                       let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                        paths.insert((path as NSString).standardizingPath)
                    }
                }
                continuation.resume(returning: paths)
            }

            box.query.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard !finished else { return }
                finished = true
                if let observer = box.observer { NotificationCenter.default.removeObserver(observer) }
                box.query.stop()
                continuation.resume(returning: [])
            }
        }
    }
}
