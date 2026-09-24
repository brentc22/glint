import Foundation

/// Settings live in UserDefaults under these keys; the settings window binds to the
/// same keys with `@AppStorage`, so there is one source of truth.
enum Prefs {
    enum Key {
        static let saveFolder = "saveFolder"
        static let autoSave = "autoSave"
        static let copyToClipboard = "copyToClipboard"
        static let showQuickAccess = "showQuickAccess"
        static let playSound = "playSound"
        static let autoRedact = "autoRedact"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.saveFolder: defaultFolder.path,
            Key.autoSave: true,
            Key.copyToClipboard: true,
            Key.showQuickAccess: true,
            Key.playSound: true,
            Key.autoRedact: false,
        ])
    }

    static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Glint")

    static var saveFolder: URL {
        URL(fileURLWithPath: UserDefaults.standard.string(forKey: Key.saveFolder) ?? defaultFolder.path)
    }
    static var autoSave: Bool { UserDefaults.standard.bool(forKey: Key.autoSave) }
    static var copyToClipboard: Bool { UserDefaults.standard.bool(forKey: Key.copyToClipboard) }
    static var showQuickAccess: Bool { UserDefaults.standard.bool(forKey: Key.showQuickAccess) }
    static var playSound: Bool { UserDefaults.standard.bool(forKey: Key.playSound) }
    static var autoRedact: Bool { UserDefaults.standard.bool(forKey: Key.autoRedact) }
}
