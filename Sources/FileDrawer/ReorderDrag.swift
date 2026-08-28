import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 行内拖拽排序的载荷识别
//
// 排序拖拽与「拖出文件」「外部拖入」共用同一条目 provider（同一个把手拖到抽屉外
// 依然能拷贝文件）。靠一个仅本进程可见的自定义 UTType 标记「这是抽屉内部的
// 排序拖拽」：行级 onDrop 只对该类型生效，外部拖拽（无此类型）自然落到
// 抽屉级的「放入文件」接收器上，互不干扰。

enum ReorderDrag {
    static let typeIdentifier = "com.wangxiao.filedrawer.reorder"

    static var type: UTType {
        UTType(typeIdentifier) ?? UTType(exportedAs: typeIdentifier)
    }

    /// 把条目 id 注册进 provider（仅本进程可见，不影响文件拖出语义）
    static func register(_ provider: NSItemProvider, id: UUID) {
        provider.registerDataRepresentation(
            forTypeIdentifier: typeIdentifier,
            visibility: .ownProcess
        ) { completion in
            completion(id.uuidString.data(using: .utf8), nil)
            return nil
        }
    }

    /// 同步判定拖拽 provider 是否携带内部排序标记。
    /// 不要用 `itemProviders(for: [ReorderDrag.type])` 做内外判别：动态自定义
    /// UTType 的符合性匹配在真实拖拽会话里会误命中外部文件 provider（实测
    /// 访达拖入时该查询返回非空），导致抽屉把所有外部拖入都当成内部排序拒收。
    /// 直接查 provider 注册的类型标识是确定性的：内部拖拽注册过该标识，
    /// 外部拖拽（访达/浏览器等）不可能有。
    static func isReorderProvider(_ provider: NSItemProvider) -> Bool {
        provider.registeredTypeIdentifiers.contains(typeIdentifier)
    }

    /// 从 provider 同步取出条目 id（内部拖拽的 provider 即时回调，不会久等）
    static func itemID(from provider: NSItemProvider) -> UUID? {
        var result: UUID?
        let semaphore = DispatchSemaphore(value: 0)
        _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
            if let data, let raw = String(data: data, encoding: .utf8) {
                result = UUID(uuidString: raw)
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1)
        return result
    }
}
