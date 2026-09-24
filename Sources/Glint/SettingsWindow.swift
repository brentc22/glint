import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var saveFolder = Prefs.saveFolder
    @Published var showQuickAccess = Prefs.showQuickAccess { didSet { defaults.set(showQuickAccess, forKey: Prefs.Key.showQuickAccess) } }
    @Published var copyToClipboard = Prefs.copyToClipboard { didSet { defaults.set(copyToClipboard, forKey: Prefs.Key.copyToClipboard) } }
    @Published var autoSave = Prefs.autoSave { didSet { defaults.set(autoSave, forKey: Prefs.Key.autoSave) } }
    @Published var playSound = Prefs.playSound { didSet { defaults.set(playSound, forKey: Prefs.Key.playSound) } }
    @Published var autoRedact = Prefs.autoRedact { didSet { defaults.set(autoRedact, forKey: Prefs.Key.autoRedact) } }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                try launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
    @Published var hasPermission = Capturer.hasPermission

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveFolder
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveFolder = url
        defaults.set(url.path, forKey: Prefs.Key.saveFolder)
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(shortcuts: [(String, String)]) {
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 560),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Glint Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: SettingsModel(), shortcuts: shortcuts))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let shortcuts: [(String, String)]

    var body: some View {
        Form {
            Section("After capture") {
                Toggle("Show quick access overlay", isOn: $model.showQuickAccess)
                Toggle("Copy to clipboard", isOn: $model.copyToClipboard)
                Toggle("Save to folder", isOn: $model.autoSave)
                Toggle("Play sound", isOn: $model.playSound)
                Toggle("Redact sensitive data automatically", isOn: $model.autoRedact)
                    .help("Emails, phone numbers, IBANs, card numbers, API keys, tokens and IP addresses — detected on-device")
            }
            Section("Save location") {
                HStack {
                    Text(model.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .truncationMode(.middle)
                        .lineLimit(1)
                    Spacer()
                    Button("Change…", action: model.chooseFolder)
                    Button("Show") { NSWorkspace.shared.open(model.saveFolder) }
                }
            }
            Section("Shortcuts") {
                ForEach(shortcuts, id: \.0) { name, keys in
                    LabeledContent(name) { Text(keys).font(.system(.body, design: .monospaced)) }
                }
            }
            Section("General") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                LabeledContent("Screen Recording") {
                    if model.hasPermission {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open System Settings") { Permission.openSettings() }
                    }
                }
            }
            Section {
                HStack {
                    Text("Glint \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") · MIT License")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link("GitHub", destination: URL(string: "https://github.com/brentc22/glint")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
