import AppKit
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
