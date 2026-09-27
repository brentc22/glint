import AppKit
import Carbon.HIToolbox

/// Every capture you can trigger — one list feeding the menu, the global shortcuts and
/// the Shortcuts settings, so they can't drift apart.
enum CaptureCommand: String, CaseIterable, Identifiable {
    case area, window, fullScreen, previousArea, scrolling, text, recording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: "Capture Area"
        case .window: "Capture Window"
        case .fullScreen: "Capture Full Screen"
        case .previousArea: "Capture Previous Area"
        case .scrolling: "Scrolling Capture"
        case .text: "Capture Text"
        case .recording: "Record Screen"
        }
    }

    var symbol: String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .fullScreen: "display"
        case .previousArea: "arrow.counterclockwise.circle"
        case .scrolling: "arrow.up.and.down.text.horizontal"
        case .text: "text.viewfinder"
        case .recording: "record.circle"
        }
    }

    /// The three macOS keeps for itself — ⇧⌘3, ⇧⌘4 (Space for a window) and ⇧⌘5 — do the
    /// same here, so muscle memory carries over. The rest have no macOS counterpart.
    var defaultShortcut: HotKeys.Combo {
        let (key, modifiers): (Int, NSEvent.ModifierFlags) = switch self {
        case .fullScreen: (kVK_ANSI_3, [.shift, .command])
        case .area: (kVK_ANSI_4, [.shift, .command])
        case .recording: (kVK_ANSI_5, [.shift, .command])
        case .window: (kVK_ANSI_5, [.control, .shift])
        case .previousArea: (kVK_ANSI_6, [.control, .shift])
        case .scrolling: (kVK_ANSI_7, [.control, .shift])
        case .text: (kVK_ANSI_2, [.control, .shift])
        }
        return HotKeys.Combo(keyCode: key, modifiers: modifiers)
    }

    /// `nil` when the user cleared it.
    var shortcut: HotKeys.Combo? {
        get {
            guard let stored = UserDefaults.standard.string(forKey: key) else { return defaultShortcut }
            return HotKeys.Combo(string: stored)
        }
        nonmutating set { UserDefaults.standard.set(newValue?.string ?? "", forKey: key) }
    }

    func resetShortcut() { UserDefaults.standard.removeObject(forKey: key) }

    private var key: String { "shortcut.\(rawValue)" }
}
