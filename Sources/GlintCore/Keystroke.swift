import Foundation

/// What a recording shows for a key press: shortcuts and special keys, never plain typing.
/// "⌘⇧K" and "↩" tell the viewer what happened; the letters of a password typed while
/// recording would tell them far too much.
public enum Keystroke {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// Keys worth showing on their own, by macOS virtual key code.
    static let special: [Int: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// `nil` when the press is typing: a character with no ⌘ or ⌃ (⇧ and ⌥ alone only pick
    /// which character comes out). `characters` is the key without modifiers applied.
    public static func label(keyCode: Int, characters: String?, modifiers: Modifiers) -> String? {
        let key: String
        if let name = special[keyCode] {
            key = name
        } else {
            guard modifiers.contains(.command) || modifiers.contains(.control) else { return nil }
            if keyCode == 49 {
                key = "Space"
            } else {
                guard let c = characters?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty else { return nil }
                key = c.uppercased()
            }
        }
        var prefix = ""
        if modifiers.contains(.control) { prefix += "⌃" }
        if modifiers.contains(.option) { prefix += "⌥" }
        if modifiers.contains(.shift) { prefix += "⇧" }
        if modifiers.contains(.command) { prefix += "⌘" }
        return prefix + key
    }
}
