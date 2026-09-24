import AppKit
import Carbon.HIToolbox

/// Global shortcuts via Carbon's `RegisterEventHotKey` — the one route that needs no
/// Accessibility permission (`NSEvent.addGlobalMonitorForEvents` does).
@MainActor
final class HotKeys {
    struct Combo {
        let keyCode: Int
        let modifiers: NSEvent.ModifierFlags

        /// `⌃⇧4` — shown in the menu next to each action.
        var symbol: String {
            var s = ""
            if modifiers.contains(.control) { s += "⌃" }
            if modifiers.contains(.option) { s += "⌥" }
            if modifiers.contains(.shift) { s += "⇧" }
            if modifiers.contains(.command) { s += "⌘" }
            return s + (Self.keyNames[keyCode] ?? "?")
        }

        var keyEquivalent: String { (Self.keyNames[keyCode] ?? "").lowercased() }

        static let keyNames: [Int: String] = [
            kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5",
            kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9", kVK_ANSI_0: "0",
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
