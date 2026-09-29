import CoreGraphics
import Foundation
import GlintCore

/// All settings, in UserDefaults. The settings window writes through `SettingsModel`;
/// everything else reads here.
enum Prefs {
    enum Corner: String, CaseIterable { case left, right }
    enum Format: String, CaseIterable { case png, jpeg }
    /// How Redact covers what it finds. Both draw only block averages, so both are safe.
    enum RedactStyle: String, CaseIterable {
        case pixelate, blur
        func kind(_ rect: CGRect) -> Annotation.Kind { self == .blur ? .blur(rect) : .pixelate(rect) }
    }
    /// How long motion takes: scales every spring's response and every fade.
    enum MotionSpeed: String, CaseIterable {
        case relaxed, standard, snappy
        var scale: Double { switch self { case .relaxed: 1.35; case .standard: 1; case .snappy: 0.72 } }
    }
    /// How much a spring overshoots before it settles.
    enum MotionBounce: String, CaseIterable {
        case none, subtle, playful
        var scale: Double { switch self { case .none: 0; case .subtle: 1; case .playful: 2 } }
    }

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
            "windowShadow": true,
            "format": Format.png.rawValue,
            "downscaleRetina": false,
            "filenamePrefix": "Glint",
            "autoRedact": false,
            "redactKinds": SensitiveMatcher.Kind.allCases.map(\.rawValue),
            "customTerms": "",
            "redactStyle": RedactStyle.pixelate.rawValue,
            "motionEnabled": true,
            "motionSpeed": MotionSpeed.standard.rawValue,
            "motionBounce": MotionBounce.subtle.rawValue,
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
    static var windowShadow: Bool { d.bool(forKey: "windowShadow") }
    static var format: Format { Format(rawValue: d.string(forKey: "format") ?? "") ?? .png }
    static var downscaleRetina: Bool { d.bool(forKey: "downscaleRetina") }
    static var filenamePrefix: String { d.string(forKey: "filenamePrefix") ?? "Glint" }
    static var autoRedact: Bool { d.bool(forKey: "autoRedact") }
    static var redactKinds: Set<SensitiveMatcher.Kind> {
        Set((d.stringArray(forKey: "redactKinds") ?? []).compactMap(SensitiveMatcher.Kind.init))
    }
    /// Off: movement becomes plain fades, as with Reduce Motion.
    static var motionEnabled: Bool { d.bool(forKey: "motionEnabled") }
    static var motionSpeed: MotionSpeed { MotionSpeed(rawValue: d.string(forKey: "motionSpeed") ?? "") ?? .standard }
    static var motionBounce: MotionBounce { MotionBounce(rawValue: d.string(forKey: "motionBounce") ?? "") ?? .subtle }
    static var redactStyle: RedactStyle { RedactStyle(rawValue: d.string(forKey: "redactStyle") ?? "") ?? .pixelate }
    static var customTerms: [String] {
        (d.string(forKey: "customTerms") ?? "").split(whereSeparator: \.isNewline).map(String.init)
    }
}
