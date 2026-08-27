import AppKit
import Carbon.HIToolbox

/// Carbon 全局热键：在任意应用前台时触发展开 / 收起抽屉。
/// 同一时间只注册一个组合；update 传入相同组合时跳过重注册（设置面板滑块等无关变更不会反复注册）。
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// 四字符签名 'fdhk'
    private static let signature = OSType(0x6664_686B)

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var currentBinding: HotKeyBinding?
    private var action: (() -> Void)?

    var isRegistered: Bool { hotKeyRef != nil }

    /// NSEvent 修饰键 → Carbon 修饰键位
    nonisolated static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var value = 0
        if flags.contains(.command) { value |= cmdKey }
        if flags.contains(.option) { value |= optionKey }
        if flags.contains(.control) { value |= controlKey }
        if flags.contains(.shift) { value |= shiftKey }
        return value
    }

    /// 注册 / 替换热键；binding 为 nil 时仅注销。
    func update(_ binding: HotKeyBinding?, action: @escaping () -> Void) {
        self.action = action
        guard binding != currentBinding else { return }
        unregisterCurrent()
        currentBinding = binding

        guard let binding, binding.isValid else { return }
        let carbon = Self.carbonModifiers(from: binding.modifiers)
        guard carbon != 0 else { return }

        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            UInt32(carbon),
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        }
    }

    /// 完全注销并清空回调
    func unregister() {
        unregisterCurrent()
        action = nil
    }

    private func unregisterCurrent() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        currentBinding = nil
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let firedSignature = hotKeyID.signature
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    center.fire(signature: firedSignature)
                }
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    private func fire(signature: OSType) {
        guard signature == Self.signature, currentBinding != nil else { return }
        action?()
    }
}
