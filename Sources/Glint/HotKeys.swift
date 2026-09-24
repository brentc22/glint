import AppKit
import Carbon.HIToolbox

/// Global shortcuts via Carbon's `RegisterEventHotKey` — the one route that needs no
/// Accessibility permission (`NSEvent.addGlobalMonitorForEvents` does).
@MainActor
final class HotKeys {
    struct Combo: Equatable {
        let keyCode: Int
        let modifiers: NSEvent.ModifierFlags

        /// Stored as "keyCode:modifiers" in UserDefaults.
        init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
            self.keyCode = keyCode
            self.modifiers = modifiers.intersection([.command, .option, .control, .shift])
        }

        init?(string: String) {
            let parts = string.split(separator: ":").compactMap { UInt($0) }
            guard parts.count == 2 else { return nil }
            self.init(keyCode: Int(parts[0]), modifiers: NSEvent.ModifierFlags(rawValue: parts[1]))
        }

        var string: String { "\(keyCode):\(modifiers.rawValue)" }

        /// `⌃⇧4` — shown in the menu next to each action.
        var symbol: String {
            var s = ""
            if modifiers.contains(.control) { s += "⌃" }
            if modifiers.contains(.option) { s += "⌥" }
            if modifiers.contains(.shift) { s += "⇧" }
            if modifiers.contains(.command) { s += "⌘" }
            return s + keyName
        }

        var keyEquivalent: String { keyName.count == 1 ? keyName.lowercased() : "" }

        /// The character the key produces on the current keyboard layout, with the combo's
        /// Shift applied — on AZERTY the "4" key types "'" and only Shift makes it "4" —
        /// and names for keys that produce no character.
        var keyName: String {
            if let special = Self.specialKeys[keyCode] { return special }
            guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
            let layout = unsafeBitCast(data, to: CFData.self)
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
                UCKeyTranslate($0, UInt16(keyCode), UInt16(kUCKeyActionDisplay),
                               modifiers.contains(.shift) ? UInt32(shiftKey >> 8) : 0, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
            }
            guard status == noErr, length > 0 else { return "?" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }

        static let specialKeys: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
    }

    nonisolated(unsafe) private static var handlers: [UInt32: @MainActor @Sendable () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let handler = HotKeys.handlers[id.id] { DispatchQueue.main.async { handler() } }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        Self.handlers.removeAll()
    }

    /// Returns `false` when another app already owns the combination.
    @discardableResult
    func register(_ combo: Combo, _ action: @escaping @MainActor @Sendable () -> Void) -> Bool {
        let id = UInt32(Self.handlers.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(combo.keyCode), carbon(combo.modifiers),
                                         EventHotKeyID(signature: 0x474C4E54 /* GLNT */, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        Self.handlers[id] = action
        return true
    }

    private func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var c: UInt32 = 0
        if flags.contains(.command) { c |= UInt32(cmdKey) }
        if flags.contains(.option) { c |= UInt32(optionKey) }
        if flags.contains(.control) { c |= UInt32(controlKey) }
        if flags.contains(.shift) { c |= UInt32(shiftKey) }
        return c
    }
}
