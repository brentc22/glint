import AppKit

/// Screen Recording is the one permission Glint needs. macOS only shows its own prompt
/// once; after that we have to send people to System Settings ourselves.
@MainActor
enum Permission {
    static func ensure() -> Bool {
        if Capturer.hasPermission { return true }
        if CGRequestScreenCaptureAccess() { return true }
        let alert = NSAlert()
        alert.messageText = "Glint needs Screen Recording permission"
        alert.informativeText = """
            Turn on Glint in System Settings → Privacy & Security → Screen & System Audio Recording, \
            then quit and reopen Glint.

            Everything stays on your Mac: Glint has no network access and no analytics.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
        return false
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
