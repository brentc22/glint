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
        // Show clashes from the start, not only after the first edit.
        conflicts = Set(onShortcutsChanged())
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
    @Published var hideDesktopIcons = Prefs.hideDesktopIcons { didSet { d.set(hideDesktopIcons, forKey: "hideDesktopIcons") } }

    // Files
    @Published var saveFolder = Prefs.saveFolder
    @Published var format = Prefs.format { didSet { d.set(format.rawValue, forKey: "format") } }
    @Published var downscaleRetina = Prefs.downscaleRetina { didSet { d.set(downscaleRetina, forKey: "downscaleRetina") } }
    @Published var filenamePrefix = Prefs.filenamePrefix { didSet { d.set(filenamePrefix, forKey: "filenamePrefix") } }

    // Redaction
    @Published var autoRedact = Prefs.autoRedact { didSet { d.set(autoRedact, forKey: "autoRedact") } }
    @Published var redactKinds = Prefs.redactKinds { didSet { d.set(redactKinds.map(\.rawValue), forKey: "redactKinds") } }
    @Published var redactStyle = Prefs.redactStyle { didSet { d.set(redactStyle.rawValue, forKey: "redactStyle") } }
    // Recording
    @Published var recordFPS = Prefs.recordFPS { didSet { d.set(recordFPS, forKey: "recordFPS") } }
    @Published var recordSystemAudio = Prefs.recordSystemAudio { didSet { d.set(recordSystemAudio, forKey: "recordSystemAudio") } }
    @Published var recordMicrophone = Prefs.recordMicrophone { didSet { d.set(recordMicrophone, forKey: "recordMicrophone") } }
    @Published var recordClicks = Prefs.recordClicks { didSet { d.set(recordClicks, forKey: "recordClicks") } }
    @Published var recordKeystrokes = Prefs.recordKeystrokes {
        didSet {
            d.set(recordKeystrokes, forKey: "recordKeystrokes")
            if recordKeystrokes { KeystrokeHUD.requestPermission() }
        }
    }
    @Published var recordWebcam = Prefs.recordWebcam { didSet { d.set(recordWebcam, forKey: "recordWebcam") } }
    @Published var recordCountdown = Prefs.recordCountdown { didSet { d.set(recordCountdown, forKey: "recordCountdown") } }
    // Upload
    @Published var uploadEndpoint = UserDefaults.standard.string(forKey: "uploadEndpoint") ?? "" { didSet { d.set(uploadEndpoint, forKey: "uploadEndpoint") } }
    @Published var uploadRegion = UserDefaults.standard.string(forKey: "uploadRegion") ?? "auto" { didSet { d.set(uploadRegion, forKey: "uploadRegion") } }
    @Published var uploadBucket = UserDefaults.standard.string(forKey: "uploadBucket") ?? "" { didSet { d.set(uploadBucket, forKey: "uploadBucket") } }
    @Published var uploadAccessKey = UserDefaults.standard.string(forKey: "uploadAccessKey") ?? "" { didSet { d.set(uploadAccessKey, forKey: "uploadAccessKey") } }
    @Published var uploadSecret = Keychain.secret ?? "" { didSet { Keychain.secret = uploadSecret } }
    @Published var uploadPublicURL = UserDefaults.standard.string(forKey: "uploadPublicURL") ?? "" { didSet { d.set(uploadPublicURL, forKey: "uploadPublicURL") } }
    @Published var redactBeforeUpload = Prefs.redactBeforeUpload { didSet { d.set(redactBeforeUpload, forKey: "redactBeforeUpload") } }
    @Published var uploadTest: String?

    func testUpload() {
        uploadTest = "Uploading a test file…"
        Task {
            do {
                let url = try await Uploader.upload(Data("Glint upload test\n".utf8), ext: "txt", contentType: "text/plain")
                uploadTest = "Works: \(url.absoluteString)"
            } catch {
                uploadTest = error.localizedDescription
            }
        }
    }
    // Motion
    @Published var motionEnabled = Prefs.motionEnabled { didSet { d.set(motionEnabled, forKey: "motionEnabled") } }
    @Published var motionSpeed = Prefs.motionSpeed { didSet { d.set(motionSpeed.rawValue, forKey: "motionSpeed") } }
    @Published var motionBounce = Prefs.motionBounce { didSet { d.set(motionBounce.rawValue, forKey: "motionBounce") } }

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
                ("Recording", "record.circle", AnyView(RecordingPane(model: model))),
                ("Redaction", "eye.slash", AnyView(RedactionPane(model: model))),
                ("Upload", "icloud.and.arrow.up", AnyView(UploadPane(model: model))),
                ("Motion", "wand.and.rays", AnyView(MotionPane(model: model))),
                ("About", "info.circle", AnyView(AboutPane())),
            ] {
                let host = NSHostingController(rootView: view.frame(width: 640).fixedSize(horizontal: false, vertical: true))
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
            Section {
                Toggle("Include the mouse pointer", isOn: $model.showCursor)
                Toggle("Add a shadow to window captures", isOn: $model.windowShadow)
                Toggle("Hide desktop icons and widgets", isOn: $model.hideDesktopIcons)
            } header: {
                Text("Screenshots")
            } footer: {
                note("Only in screenshots and recordings. Your desktop stays as it is, and Finder isn't restarted.")
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
                                    .help("Another app, or macOS itself, already uses this shortcut")
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
            if !model.conflicts.isEmpty {
                Section {
                    HStack(alignment: .top) {
                        note("A shortcut marked ⚠︎ is taken. If it's ⇧⌘3, ⇧⌘4 or ⇧⌘5, turn off macOS's own under Keyboard Shortcuts → Screenshots.")
                        Button("Open Keyboard Shortcuts", action: SystemShortcuts.openKeyboardShortcuts)
                    }
                }
            }
            Section("While selecting") {
                LabeledContent("Switch area / window") { Text("Space") }
                LabeledContent("Capture the whole screen") { Text("↩") }
                LabeledContent("Copy the color under the cursor") { Text("C") }
                LabeledContent("Aspect ratio or fixed size") { Text("R") }
                LabeledContent("Cancel") { Text("Esc") }
            }
        }
        .formStyle(.grouped)
    }
}

private struct RecordingPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Frame rate", selection: $model.recordFPS) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented)
                Toggle("Count down 3 seconds before recording", isOn: $model.recordCountdown)
            }
            Section {
                Toggle("Record system audio", isOn: $model.recordSystemAudio)
                Toggle("Record the microphone", isOn: $model.recordMicrophone)
                    .disabled(!Recorder.canRecordMicrophone)
            } header: {
                Text("Sound")
            } footer: {
                note(Recorder.canRecordMicrophone
                     ? "With both on, they're mixed into one track, so every player plays your voice. Glint's own sounds are left out."
                     : "The microphone needs macOS 15 or later.")
            }
            Section {
                Toggle("Show clicks", isOn: $model.recordClicks)
                Toggle("Show keyboard shortcuts", isOn: $model.recordKeystrokes)
                Toggle("Show the webcam", isOn: $model.recordWebcam)
            } header: {
                Text("In the video")
            } footer: {
                note("Shortcuts like ⌘⇧K and keys like ↩ appear; plain typing never does, so a password typed while recording stays private. Seeing other apps' shortcuts needs Accessibility. The webcam bubble can be dragged anywhere while recording.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct UploadPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                TextField("Endpoint", text: $model.uploadEndpoint, prompt: Text("https://<account>.r2.cloudflarestorage.com"))
                TextField("Region", text: $model.uploadRegion, prompt: Text("auto"))
                TextField("Bucket", text: $model.uploadBucket)
                TextField("Access key ID", text: $model.uploadAccessKey)
                SecureField("Secret access key", text: $model.uploadSecret)
                TextField("Public link starts with", text: $model.uploadPublicURL, prompt: Text("https://shots.example.com"))
            } header: {
                Text("Your bucket")
            } footer: {
                note("Any S3-compatible storage: Cloudflare R2 (free up to 10 GB), AWS S3, Backblaze B2, MinIO. Links use random names that can't be guessed. The secret key is kept in your Keychain. Until this is filled in, Glint never touches the network.")
            }
            Section {
                Toggle("Redact screenshots before uploading", isOn: $model.redactBeforeUpload)
                LabeledContent("Check the setup") {
                    HStack {
                        if let result = model.uploadTest {
                            Text(result).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        }
                        Button("Test Upload", action: model.testUpload)
                    }
                }
            } footer: {
                note("A shared link travels further than a file, so Glint hides emails, IBANs, keys and your own terms in the uploaded copy. The screenshot on your Mac stays as it is.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct MotionPane: View {
    @ObservedObject var model: SettingsModel
    private var systemReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        Form {
            Section {
                Toggle("Animate windows and thumbnails", isOn: $model.motionEnabled)
            } footer: {
                if systemReduced {
                    note("Reduce Motion is on in System Settings → Accessibility, so Glint only fades.")
                } else {
                    note("Off: things fade in and out instead of moving.")
                }
            }
            Section {
                Picker("Speed", selection: $model.motionSpeed) {
                    Text("Relaxed").tag(Prefs.MotionSpeed.relaxed)
                    Text("Standard").tag(Prefs.MotionSpeed.standard)
                    Text("Snappy").tag(Prefs.MotionSpeed.snappy)
                }
                .pickerStyle(.segmented)
                .disabled(!model.motionEnabled || systemReduced)
                Picker("Bounce", selection: $model.motionBounce) {
                    Text("None").tag(Prefs.MotionBounce.none)
                    Text("Subtle").tag(Prefs.MotionBounce.subtle)
                    Text("Playful").tag(Prefs.MotionBounce.playful)
                }
                .pickerStyle(.segmented)
                .disabled(!model.motionEnabled || systemReduced)
                LabeledContent("Try it") {
                    Button("Show a toast") { Toast.show("This is how Glint moves", symbol: "sparkles") }
                }
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
                Picker("Cover with", selection: $model.redactStyle) {
                    Text("Pixels").tag(Prefs.RedactStyle.pixelate)
                    Text("Blur").tag(Prefs.RedactStyle.blur)
                }
                .pickerStyle(.segmented)
            } footer: {
                note("Off: use the Redact button in the overlay or editor when you need it. Glint's blur is made from block averages, like the pixels, so it can't be sharpened back.")
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
