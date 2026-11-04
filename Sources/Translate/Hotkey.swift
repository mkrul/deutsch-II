import AppKit
import Carbon.HIToolbox

struct Hotkey: Equatable {
    var keyCode: Int
    var modifiers: NSEvent.ModifierFlags
    var label: String

    static let `default` = Hotkey(keyCode: 17, modifiers: [.control, .option], label: "T")
    static let regionDefault = Hotkey(keyCode: 15, modifiers: [.control, .option], label: "R")
    static let wordDefault = Hotkey(keyCode: 13, modifiers: [.control, .option], label: "W")

    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        text += label
        return text
    }

    static func modifierLabel(for keyCode: Int) -> String? {
        switch keyCode {
        case 54, 55: return "⌘"
        case 58, 61: return "⌥"
        case 59, 62: return "⌃"
        case 56, 60: return "⇧"
        case 63: return "fn"
        default: return nil
        }
    }

    static func sameModifier(_ registered: Int, _ eventCode: Int) -> Bool {
        guard let left = modifierLabel(for: registered), let right = modifierLabel(for: eventCode) else { return false }
        return left == right
    }

    static func modifierIsDown(_ keyCode: Int, flags: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case 54, 55: return flags.contains(.command)
        case 58, 61: return flags.contains(.option)
        case 59, 62: return flags.contains(.control)
        case 56, 60: return flags.contains(.shift)
        case 63: return flags.contains(.function)
        default: return false
        }
    }

    static func modifierIsDown(_ keyCode: Int, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 54, 55: return flags.contains(.maskCommand)
        case 58, 61: return flags.contains(.maskAlternate)
        case 59, 62: return flags.contains(.maskControl)
        case 56, 60: return flags.contains(.maskShift)
        case 63: return flags.contains(.maskSecondaryFn)
        default: return false
        }
    }

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        return value
    }

    static func label(for event: NSEvent) -> String {
        let names: [UInt16: String] = [
            36: "↩",
            48: "⇥",
            49: "Space",
            51: "⌫",
            115: "Home",
            116: "PgUp",
            117: "⌦",
            119: "End",
            121: "PgDn",
            123: "←",
            124: "→",
            125: "↓",
            126: "↑",
            122: "F1",
            120: "F2",
            99: "F3",
            118: "F4",
            96: "F5",
            97: "F6",
            98: "F7",
            100: "F8",
            101: "F9",
            109: "F10",
            103: "F11",
            111: "F12",
        ]
        if let name = names[event.keyCode] {
            return name
        }
        let raw = event.charactersIgnoringModifiers ?? ""
        let trimmed = raw.trimmingCharacters(in: .controlCharacters.union(.newlines))
        if trimmed.count == 1, let character = trimmed.first {
            if character.isLetter {
                return String(character).uppercased()
            }
            return String(character)
        }
        return "Key \(event.keyCode)"
    }
}

final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private var held = Set<UInt32>()
    private var unlocks: [UInt32: DispatchWorkItem] = [:]
    private var plainKeys: [UInt32: Int] = [:]
    private var modifierHeld: [UInt32: Bool] = [:]
    private var plainTap: CFMachPort?
    private var plainSource: CFRunLoopSource?

    func register(region: Hotkey, word: Hotkey) -> String? {
        installHandlerIfNeeded()
        unregisterKeys()
        if let message = install(region, id: 2) { return message }
        if let message = install(word, id: 3) {
            unregisterKeys()
            _ = install(region, id: 2)
            return message
        }
        return nil
    }

    func unregister() {
        unregisterKeys()
        held.removeAll()
        for unlock in unlocks.values { unlock.cancel() }
        unlocks.removeAll()
    }

    fileprivate func press(_ id: UInt32) {
        if held.contains(id) {
            scheduleUnlock(id)
            return
        }
        held.insert(id)
        scheduleUnlock(id)
        Task { @MainActor in
            if id == 2 {
                AppModel.shared.regionHotkeyPressed()
            } else if id == 3 {
                AppModel.shared.wordHotkeyPressed()
            } else {
                AppModel.shared.hotkeyPressed()
            }
        }
    }

    private func scheduleUnlock(_ id: UInt32) {
        unlocks[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.held.remove(id)
        }
        unlocks[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    fileprivate func release(_ id: UInt32) {
        held.remove(id)
        unlocks[id]?.cancel()
        unlocks[id] = nil
    }

    private func install(_ hotkey: Hotkey, id: UInt32) -> String? {
        let bare = hotkey.modifiers.intersection([.command, .control, .option, .shift]).isEmpty
        if bare {
            if let message = installPlainTap() { return message }
            plainKeys[id] = hotkey.keyCode
            held.remove(id)
            return nil
        }
        plainKeys[id] = nil
        if plainKeys.isEmpty { removePlainTap() }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(hotkey.keyCode),
            hotkey.carbonModifiers,
            EventHotKeyID(signature: 0x54524E53, id: id),
            GetApplicationEventTarget(),
            UInt32(kEventHotKeyExclusive),
            &ref
        )
        if status != noErr {
            return "That hotkey is already used. Choose another."
        }
        if let ref { refs[id] = ref }
        held.remove(id)
        return nil
    }

    private func installPlainTap() -> String? {
        if plainTap != nil { return nil }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue) | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                HotkeyCenter.shared.receivePlain(type: type, event: event)
            },
            userInfo: nil
        ) else {
            return "That key could not be registered."
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        plainTap = tap
        plainSource = source
        return nil
    }

    private func plainID(for code: Int) -> UInt32? {
        if let exact = plainKeys.first(where: { $0.value == code })?.key {
            return exact
        }
        let siblings = plainKeys.filter { Hotkey.sameModifier($0.value, code) }
        guard siblings.count == 1 else { return nil }
        return siblings.first?.key
    }

    private func removePlainTap() {
        if let plainTap {
            CGEvent.tapEnable(tap: plainTap, enable: false)
            CFMachPortInvalidate(plainTap)
            self.plainTap = nil
        }
        if let plainSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), plainSource, .commonModes)
            self.plainSource = nil
        }
    }

    fileprivate func receivePlain(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let plainTap { CGEvent.tapEnable(tap: plainTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .flagsChanged {
            guard let id = plainID(for: code) else {
                return Unmanaged.passUnretained(event)
            }
            if Hotkey.modifierIsDown(code, flags: event.flags) {
                modifierHeld[id] = true
            } else if modifierHeld[id] == true {
                modifierHeld[id] = nil
                DispatchQueue.main.async {
                    self.press(id)
                    self.release(id)
                }
            } else {
                modifierHeld[id] = nil
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown {
            for id in modifierHeld.keys { modifierHeld[id] = false }
        }
        let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        if !event.flags.intersection(modifiers).isEmpty {
            return Unmanaged.passUnretained(event)
        }
        guard let id = plainKeys.first(where: { $0.value == code })?.key else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyUp {
            DispatchQueue.main.async { self.release(id) }
            return nil
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return nil
        }
        DispatchQueue.main.async { self.press(id) }
        return nil
    }

    private func unregisterKeys() {
        for ref in refs.values {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
        plainKeys.removeAll()
        modifierHeld.removeAll()
        removePlainTap()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            2,
            &specs,
            nil,
            &handlerRef
        )
    }
}

private func hotKeyEventHandler(
    _ next: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    let id = status == noErr ? hotKeyID.id : 1
    let kind = GetEventKind(event)
    if kind == UInt32(kEventHotKeyPressed) {
        DispatchQueue.main.async {
            HotkeyCenter.shared.press(id)
        }
    } else if kind == UInt32(kEventHotKeyReleased) {
        DispatchQueue.main.async {
            HotkeyCenter.shared.release(id)
        }
    }
    return noErr
}
