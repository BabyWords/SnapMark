import AppKit
import Carbon.HIToolbox

/// 一个全局快捷键组合
struct HotKeyCombo: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32          // Carbon: cmdKey | shiftKey | optionKey | controlKey
    var keyTitle: String           // 仅用于显示

    static let `default` = HotKeyCombo(keyCode: UInt32(kVK_ANSI_X),
                                       modifiers: UInt32(cmdKey | shiftKey),
                                       keyTitle: "X")

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyTitle
    }

    var hasPrimaryModifier: Bool {
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    /// 从键盘事件构造；没有 ⌘/⌥/⌃ 时返回 nil（避免抢占普通按键）
    static func from(event: NSEvent) -> HotKeyCombo? {
        var carbon: UInt32 = 0
        let f = event.modifierFlags
        if f.contains(.command) { carbon |= UInt32(cmdKey) }
        if f.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if f.contains(.option)  { carbon |= UInt32(optionKey) }
        if f.contains(.control) { carbon |= UInt32(controlKey) }

        let combo = HotKeyCombo(keyCode: UInt32(event.keyCode),
                                modifiers: carbon,
                                keyTitle: title(for: event))
        guard combo.hasPrimaryModifier else { return nil }
        return combo
    }

    private static let specialKeys: [Int: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 76: "⌤", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
        90: "F20", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";",
        39: "'", 43: ",", 47: ".", 44: "/", 50: "`"
    ]

    static func title(for event: NSEvent) -> String {
        if let s = specialKeys[Int(event.keyCode)] { return s }
        if let s = event.charactersIgnoringModifiers?.uppercased(), !s.isEmpty {
            return s
        }
        return "键\(event.keyCode)"
    }
}

/// 快捷键持久化
enum HotKeyStore {
    private static let codeKey = "SnapMark.hotKeyCode"
    private static let modsKey = "SnapMark.hotKeyModifiers"
    private static let titleKey = "SnapMark.hotKeyTitle"

    static func load() -> HotKeyCombo {
        let d = UserDefaults.standard
        guard d.object(forKey: codeKey) != nil else { return .default }
        return HotKeyCombo(keyCode: UInt32(d.integer(forKey: codeKey)),
                           modifiers: UInt32(d.integer(forKey: modsKey)),
                           keyTitle: d.string(forKey: titleKey) ?? "?")
    }

    static func save(_ combo: HotKeyCombo) {
        let d = UserDefaults.standard
        d.set(Int(combo.keyCode), forKey: codeKey)
        d.set(Int(combo.modifiers), forKey: modsKey)
        d.set(combo.keyTitle, forKey: titleKey)
    }
}

/// 全局快捷键注册（Carbon，免辅助功能权限）
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var handler: (() -> Void)?
    private(set) var combo = HotKeyStore.load()

    func install(_ handler: @escaping () -> Void) {
        self.handler = handler
        guard handlerRef == nil else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandlerCallback, 1, &spec,
                            nil, &handlerRef)
    }

    func fire() { handler?() }

    @discardableResult
    func register(_ newCombo: HotKeyCombo) -> Bool {
        unregister()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E4150), id: 1)   // 'SNAP'
        let status = RegisterEventHotKey(newCombo.keyCode, newCombo.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        combo = newCombo
        return true
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }
}

private let hotKeyHandlerCallback: EventHandlerUPP = { _, eventRef, _ in
    guard let eventRef else { return noErr }
    var hkID = EventHotKeyID()
    GetEventParameter(eventRef, EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<EventHotKeyID>.size, nil, &hkID)
    if hkID.id == 1 {
        DispatchQueue.main.async { HotKeyManager.shared.fire() }
    }
    return noErr
}
