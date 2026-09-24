import Foundation
import GlintCore

/// All settings, in UserDefaults. The settings window writes through `SettingsModel`;
/// everything else reads here.
enum Prefs {
    enum Corner: String, CaseIterable { case left, right }
    enum Format: String, CaseIterable { case png, jpeg }

    static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Glint")

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "saveFolder": defaultFolder.path,
            "autoSave": true,
            "copyToClipboard": true,
            "showQuickAccess": true,
            "quickAccessCorner": Corner.left.rawValue,
            "quickAccessSeconds": 8,
            "openEditor": false,
            "playSound": true,
            "showCursor": false,
            "format": Format.png.rawValue,
            "downscaleRetina": false,
            "filenamePrefix": "Glint",
            "autoRedact": false,
            "redactKinds": SensitiveMatcher.Kind.allCases.map(\.rawValue),
            "customTerms": "",
        ])
    }

    private static var d: UserDefaults { .standard }

    static var saveFolder: URL { URL(fileURLWithPath: d.string(forKey: "saveFolder") ?? defaultFolder.path) }
    static var autoSave: Bool { d.bool(forKey: "autoSave") }
    static var copyToClipboard: Bool { d.bool(forKey: "copyToClipboard") }
    static var showQuickAccess: Bool { d.bool(forKey: "showQuickAccess") }
    static var quickAccessCorner: Corner { Corner(rawValue: d.string(forKey: "quickAccessCorner") ?? "") ?? .left }
    /// 0 = stay until closed.
    static var quickAccessSeconds: Int { d.integer(forKey: "quickAccessSeconds") }
    static var openEditor: Bool { d.bool(forKey: "openEditor") }
    static var playSound: Bool { d.bool(forKey: "playSound") }
    static var showCursor: Bool { d.bool(forKey: "showCursor") }
    static var format: Format { Format(rawValue: d.string(forKey: "format") ?? "") ?? .png }
    static var downscaleRetina: Bool { d.bool(forKey: "downscaleRetina") }
    static var filenamePrefix: String { d.string(forKey: "filenamePrefix") ?? "Glint" }
    static var autoRedact: Bool { d.bool(forKey: "autoRedact") }
    static var redactKinds: Set<SensitiveMatcher.Kind> {
        Set((d.stringArray(forKey: "redactKinds") ?? []).compactMap(SensitiveMatcher.Kind.init))
    }
    static var customTerms: [String] {
        (d.string(forKey: "customTerms") ?? "").split(whereSeparator: \.isNewline).map(String.init)
    }
}
