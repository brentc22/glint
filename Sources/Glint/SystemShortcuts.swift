import AppKit
import Carbon.HIToolbox

/// macOS's own screenshot shortcuts. While one is on it wins over Glint's shortcut for the
/// same keys, and `RegisterEventHotKey` doesn't say so — it succeeds and never fires.
enum SystemShortcuts {
    /// Symbolic hotkey IDs in com.apple.symbolichotkeys, with their factory keys.
    private static let screenshots: [(id: String, combo: HotKeys.Combo)] = [
        ("28", HotKeys.Combo(keyCode: kVK_ANSI_3, modifiers: [.shift, .command])),
        ("29", HotKeys.Combo(keyCode: kVK_ANSI_3, modifiers: [.control, .shift, .command])),
        ("30", HotKeys.Combo(keyCode: kVK_ANSI_4, modifiers: [.shift, .command])),
        ("31", HotKeys.Combo(keyCode: kVK_ANSI_4, modifiers: [.control, .shift, .command])),
        ("184", HotKeys.Combo(keyCode: kVK_ANSI_5, modifiers: [.shift, .command])),
    ]

    /// The macOS screenshot shortcuts that are on right now. A missing entry means the
    /// user never touched it, so it's on with its factory keys.
    static func enabledScreenshotCombos() -> [HotKeys.Combo] {
        let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys") as? [String: [String: Any]] ?? [:]
        return screenshots.compactMap { id, factory in
            guard let entry = hotkeys[id] else { return factory }
            guard entry["enabled"] as? Bool ?? true else { return nil }
            // parameters: (character, key code, Carbon-style modifier mask in NSEvent bits)
            guard let params = (entry["value"] as? [String: Any])?["parameters"] as? [Int], params.count == 3 else { return factory }
            return HotKeys.Combo(keyCode: params[1], modifiers: NSEvent.ModifierFlags(rawValue: UInt(params[2])))
        }
    }

    static func openKeyboardShortcuts() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")!)
    }
}
