import AppKit
import GlintCore
import ServiceManagement
import SwiftUI

/// Live-bound settings: each property writes to UserDefaults the moment it changes.
@MainActor
final class SettingsModel: ObservableObject {
    private let d = UserDefaults.standard
    let onShortcutsChanged: () -> [CaptureCommand]

    init(onShortcutsChanged: @escaping () -> [CaptureCommand]) {
        self.onShortcutsChanged = onShortcutsChanged
    }

    // General
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do { try launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
            catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
        }
    }
    @Published var playSound = Prefs.playSound { didSet { d.set(playSound, forKey: "playSound") } }
    @Published var hasPermission = CGPreflightScreenCaptureAccess()

    // After capture
    @Published var showQuickAccess = Prefs.showQuickAccess { didSet { d.set(showQuickAccess, forKey: "showQuickAccess") } }
    @Published var quickAccessCorner = Prefs.quickAccessCorner { didSet { d.set(quickAccessCorner.rawValue, forKey: "quickAccessCorner") } }
    @Published var quickAccessSeconds = Prefs.quickAccessSeconds { didSet { d.set(quickAccessSeconds, forKey: "quickAccessSeconds") } }
    @Published var openEditor = Prefs.openEditor { didSet { d.set(openEditor, forKey: "openEditor") } }
    @Published var copyToClipboard = Prefs.copyToClipboard { didSet { d.set(copyToClipboard, forKey: "copyToClipboard") } }
    @Published var autoSave = Prefs.autoSave { didSet { d.set(autoSave, forKey: "autoSave") } }
    @Published var showCursor = Prefs.showCursor { didSet { d.set(showCursor, forKey: "showCursor") } }
    @Published var windowShadow = Prefs.windowShadow { didSet { d.set(windowShadow, forKey: "windowShadow") } }

    // Files
    @Published var saveFolder = Prefs.saveFolder
    @Published var format = Prefs.format { didSet { d.set(format.rawValue, forKey: "format") } }
    @Published var downscaleRetina = Prefs.downscaleRetina { didSet { d.set(downscaleRetina, forKey: "downscaleRetina") } }
    @Published var filenamePrefix = Prefs.filenamePrefix { didSet { d.set(filenamePrefix, forKey: "filenamePrefix") } }

    // Redaction
    @Published var autoRedact = Prefs.autoRedact { didSet { d.set(autoRedact, forKey: "autoRedact") } }
    @Published var redactKinds = Prefs.redactKinds { didSet { d.set(redactKinds.map(\.rawValue), forKey: "redactKinds") } }
    @Published var customTerms = UserDefaults.standard.string(forKey: "customTerms") ?? "" { didSet { d.set(customTerms, forKey: "customTerms") } }

    // Shortcuts
    @Published private(set) var conflicts: Set<CaptureCommand> = []

    func setShortcut(_ command: CaptureCommand, _ combo: HotKeys.Combo?) {
        // One combination, one action: taking it here clears it elsewhere.
        if let combo {
            for other in CaptureCommand.allCases where other != command && other.shortcut == combo { other.shortcut = nil }
        }
        command.shortcut = combo
        conflicts = Set(onShortcutsChanged())
        objectWillChange.send()
    }

    func resetShortcuts() {
        CaptureCommand.allCases.forEach { $0.resetShortcut() }
        conflicts = Set(onShortcutsChanged())
        objectWillChange.send()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveFolder = url
        d.set(url.path, forKey: "saveFolder")
    }

    var sampleFilename: String { FileNaming.name(prefix: filenamePrefix, ext: format == .png ? "png" : "jpg") }
}

/// Standard macOS preferences: a toolbar of tabs, each pane sized to its content.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(tab: Int? = nil, onShortcutsChanged: @escaping () -> [CaptureCommand]) {
        if window == nil {
            let model = SettingsModel(onShortcutsChanged: onShortcutsChanged)
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            for (title, symbol, view) in [
                ("General", "gearshape", AnyView(GeneralPane(model: model))),
                ("Capture", "camera.viewfinder", AnyView(CapturePane(model: model))),
                ("Files", "folder", AnyView(FilesPane(model: model))),
                ("Shortcuts", "keyboard", AnyView(ShortcutsPane(model: model))),
                ("Redaction", "eye.slash", AnyView(RedactionPane(model: model))),
                ("About", "info.circle", AnyView(AboutPane())),
            ] {
                let host = NSHostingController(rootView: view.frame(width: 520).fixedSize(horizontal: false, vertical: true))
                host.sizingOptions = .preferredContentSize
                host.title = title  // the window title follows the selected tab
                let item = NSTabViewItem(viewController: host)
                item.label = title
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                tabs.addTabViewItem(item)
            }
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        if let tab { (window?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = tab }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Panes

/// Explanatory text under a section, left-aligned like System Settings.
private func note(_ text: String) -> some View {
    Text(text).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
}

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Launch Glint at login", isOn: $model.launchAtLogin)
                Toggle("Play a sound when capturing", isOn: $model.playSound)
            }
            Section {
                LabeledContent("Screen Recording") {
                    if model.hasPermission {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open System Settings…") { Permission.openSettings() }
                    }
                }
            } footer: {
                note("Glint needs this to see your screen. It has no network access; nothing leaves your Mac.")
            }
        }
        .formStyle(.grouped)
        .task { model.hasPermission = await Capturer.hasPermission() }
    }
}

private struct CapturePane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("After capturing") {
                Toggle("Copy to clipboard", isOn: $model.copyToClipboard)
                Toggle("Save to folder", isOn: $model.autoSave)
                Toggle("Show quick access overlay", isOn: $model.showQuickAccess)
                if model.showQuickAccess {
                    Picker("Position", selection: $model.quickAccessCorner) {
                        Text("Bottom left").tag(Prefs.Corner.left)
                        Text("Bottom right").tag(Prefs.Corner.right)
                    }
                    Picker("Close after", selection: $model.quickAccessSeconds) {
                        Text("5 seconds").tag(5)
                        Text("8 seconds").tag(8)
                        Text("15 seconds").tag(15)
                        Text("Never").tag(0)
                    }
                }
                Toggle("Open the editor right away", isOn: $model.openEditor)
            }
            Section("Screenshots") {
                Toggle("Include the mouse pointer", isOn: $model.showCursor)
                Toggle("Add a shadow to window captures", isOn: $model.windowShadow)
            }
        }
        .formStyle(.grouped)
    }
}

private struct FilesPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Save to") {
                    HStack {
                        Text(model.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .truncationMode(.middle).lineLimit(1).foregroundStyle(.secondary)
                        Button("Change…", action: model.chooseFolder)
                        Button { NSWorkspace.shared.open(model.saveFolder) } label: { Image(systemName: "arrow.up.forward.app") }
                            .help("Show in Finder")
                    }
                }
                TextField("File name starts with", text: $model.filenamePrefix)
                LabeledContent("Example") { Text(model.sampleFilename).foregroundStyle(.secondary) }
            }
            Section {
                Picker("Format", selection: $model.format) {
                    Text("PNG — sharp, lossless").tag(Prefs.Format.png)
                    Text("JPEG — smaller files").tag(Prefs.Format.jpeg)
                }
                Toggle("Save Retina screenshots at 1× size", isOn: $model.downscaleRetina)
            } footer: {
                note("1× halves width and height on Retina screens: smaller files that paste at the size you saw them.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(CaptureCommand.allCases) { command in
                    LabeledContent {
                        HStack {
                            if model.conflicts.contains(command) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    .help("Another app already uses this shortcut")
                            }
                            ShortcutRecorder(combo: command.shortcut) { model.setShortcut(command, $0) }
                        }
                    } label: {
                        Label(command.title, systemImage: command.symbol)
                    }
                }
            } footer: {
                HStack(alignment: .top) {
                    note("Click a shortcut and press new keys. ⌫ clears it, Esc cancels.")
                    Button("Restore Defaults", action: model.resetShortcuts)
                }
            }
            Section("While selecting") {
                LabeledContent("Switch area / window") { Text("Space") }
                LabeledContent("Capture the whole screen") { Text("↩") }
                LabeledContent("Copy the color under the cursor") { Text("C") }
                LabeledContent("Cancel") { Text("Esc") }
            }
        }
        .formStyle(.grouped)
    }
}

private struct RedactionPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Redact every screenshot automatically", isOn: $model.autoRedact)
            } footer: {
                note("Off: use the Redact button in the overlay or editor when you need it.")
            }
            Section("Look for") {
                ForEach(SensitiveMatcher.Kind.allCases, id: \.self) { kind in
                    Toggle(kind.title, isOn: Binding(
                        get: { model.redactKinds.contains(kind) },
                        set: { on in if on { model.redactKinds.insert(kind) } else { model.redactKinds.remove(kind) } }))
                }
            }
            if model.redactKinds.contains(.custom) {
                Section {
                    TextEditor(text: $model.customTerms)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 90)
                } header: {
                    Text("Terms to hide")
                } footer: {
                    note("One per line: customer names, project codes. Matches ignore case. Wrap in slashes for a regular expression, e.g. /INV-\\d+/")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Glint").font(.title.bold())
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Free and open source. No account, no tracking, no network access.")
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Link("GitHub", destination: URL(string: "https://github.com/brentc22/glint")!)
                Link("Report an issue", destination: URL(string: "https://github.com/brentc22/glint/issues")!)
                Link("MIT License", destination: URL(string: "https://github.com/brentc22/glint/blob/main/LICENSE")!)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }
}
