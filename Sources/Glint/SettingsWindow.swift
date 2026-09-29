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

/// Standard macOS preferences: a toolbar of tabs, each pane sized to its content. Kept to
/// what most people change, in plain words; the rest waits under More.
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
                ("Recording", "record.circle", AnyView(RecordingPane(model: model))),
                ("Privacy", "eye.slash", AnyView(PrivacyPane(model: model))),
                ("Shortcuts", "keyboard", AnyView(ShortcutsPane(model: model))),
                ("More", "ellipsis.circle", AnyView(MorePane(model: model))),
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

/// A short line under a section, left-aligned like System Settings.
private func note(_ text: String) -> some View {
    Text(text).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
}

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            if !model.hasPermission {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Glint can't see your screen yet").font(.headline)
                            Text("Turn Glint on under Screen Recording, then open it again.").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open Settings") { Permission.openSettings() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            Section("After a screenshot") {
                Toggle("Copy it, so I can paste it anywhere", isOn: $model.copyToClipboard)
                Toggle("Save it in a folder", isOn: $model.autoSave)
                if model.autoSave {
                    LabeledContent("Folder") {
                        HStack {
                            Text(model.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .truncationMode(.middle).lineLimit(1).foregroundStyle(.secondary)
                            Button("Change…", action: model.chooseFolder)
                        }
                    }
                }
                Toggle("Show a small preview in the corner", isOn: $model.showQuickAccess)
                if model.showQuickAccess {
                    Picker("Which corner", selection: $model.quickAccessCorner) {
                        Text("Left").tag(Prefs.Corner.left)
                        Text("Right").tag(Prefs.Corner.right)
                    }
                    .pickerStyle(.segmented)
                    Picker("Keep it for", selection: $model.quickAccessSeconds) {
                        Text("5 sec").tag(5)
                        Text("8 sec").tag(8)
                        Text("15 sec").tag(15)
                        Text("Until I close it").tag(0)
                    }
                }
                Toggle("Open it for drawing right away", isOn: $model.openEditor)
            }
            Section("In the picture") {
                Toggle("Show the mouse pointer", isOn: $model.showCursor)
                Toggle("Put a shadow around windows", isOn: $model.windowShadow)
                Toggle("Leave out desktop icons", isOn: $model.hideDesktopIcons)
            }
            Section {
                Toggle("Make a camera sound", isOn: $model.playSound)
                Toggle("Start Glint when my Mac starts", isOn: $model.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .task { model.hasPermission = await Capturer.hasPermission() }
    }
}

private struct RecordingPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Sound") {
                Toggle("Record the sound from my Mac", isOn: $model.recordSystemAudio)
                Toggle("Record my voice", isOn: $model.recordMicrophone)
                    .disabled(!Recorder.canRecordMicrophone)
                    .help(Recorder.canRecordMicrophone ? "Uses your microphone" : "Needs macOS 15 or later")
            }
            Section {
                Toggle("Show where I click", isOn: $model.recordClicks)
                Toggle("Show the shortcuts I press", isOn: $model.recordKeystrokes)
                Toggle("Show my face (camera)", isOn: $model.recordWebcam)
            } header: {
                Text("In the video")
            } footer: {
                note("Normal typing is never shown, so passwords stay secret.")
            }
            Section {
                Toggle("Count down 3, 2, 1 before it starts", isOn: $model.recordCountdown)
                Picker("Smoothness", selection: $model.recordFPS) {
                    Text("Normal").tag(30)
                    Text("Extra smooth").tag(60)
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacyPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Hide private info in every screenshot", isOn: $model.autoRedact)
            } footer: {
                note("Emails, phone numbers, bank and card numbers, passwords and keys get covered up. It all happens on your Mac. Off: press Redact when you need it.")
            }
            Section {
                Picker("Cover it with", selection: $model.redactStyle) {
                    Text("Squares").tag(Prefs.RedactStyle.pixelate)
                    Text("Blur").tag(Prefs.RedactStyle.blur)
                }
                .pickerStyle(.segmented)
                DisclosureGroup("Choose what to hide") {
                    ForEach(SensitiveMatcher.Kind.allCases, id: \.self) { kind in
                        Toggle(kind.title, isOn: Binding(
                            get: { model.redactKinds.contains(kind) },
                            set: { on in if on { model.redactKinds.insert(kind) } else { model.redactKinds.remove(kind) } }))
                    }
                    if model.redactKinds.contains(.custom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your own words, one per line")
                            TextEditor(text: $model.customTerms)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 70)
                            note("For example a customer's name. Capitals don't matter.")
                        }
                    }
                }
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
                    note("Click a shortcut, then press the keys you want.")
                    Button("Reset", action: model.resetShortcuts)
                }
            }
            if !model.conflicts.isEmpty {
                Section {
                    HStack(alignment: .top) {
                        note("⚠︎ means your Mac already uses that shortcut. Turn off the Mac's own screenshot shortcuts to let Glint have them.")
                        Button("Show Me", action: SystemShortcuts.openKeyboardShortcuts)
                    }
                }
            }
            Section("While choosing an area") {
                LabeledContent("Pick a window instead") { Text("Space") }
                LabeledContent("Take the whole screen") { Text("↩") }
                LabeledContent("Square, wide or exact size") { Text("R") }
                LabeledContent("Copy a color") { Text("C") }
                LabeledContent("Stop") { Text("Esc") }
            }
        }
        .formStyle(.grouped)
    }
}

/// Everything most people never touch: files, animation, share links.
private struct MorePane: View {
    @ObservedObject var model: SettingsModel
    private var systemReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        Form {
            Section("Files") {
                Picker("Type", selection: $model.format) {
                    Text("PNG, best quality").tag(Prefs.Format.png)
                    Text("JPEG, smaller").tag(Prefs.Format.jpeg)
                }
                Toggle("Make files half as big", isOn: $model.downscaleRetina)
                    .help("On sharp (Retina) screens: half the width and height")
                TextField("Name starts with", text: $model.filenamePrefix)
                LabeledContent("Looks like") { Text(model.sampleFilename).foregroundStyle(.secondary) }
            }
            Section("Animations") {
                Toggle("Move things around smoothly", isOn: $model.motionEnabled)
                    .disabled(systemReduced)
                    .help(systemReduced ? "Reduce Motion is on in your Mac's settings" : "")
                if model.motionEnabled, !systemReduced {
                    Picker("Speed", selection: $model.motionSpeed) {
                        Text("Calm").tag(Prefs.MotionSpeed.relaxed)
                        Text("Normal").tag(Prefs.MotionSpeed.standard)
                        Text("Quick").tag(Prefs.MotionSpeed.snappy)
                    }
                    .pickerStyle(.segmented)
                    Picker("Bounce", selection: $model.motionBounce) {
                        Text("None").tag(Prefs.MotionBounce.none)
                        Text("A little").tag(Prefs.MotionBounce.subtle)
                        Text("A lot").tag(Prefs.MotionBounce.playful)
                    }
                    .pickerStyle(.segmented)
                }
            }
            Section {
                DisclosureGroup("Share links (for experts)") {
                    VStack(alignment: .leading, spacing: 8) {
                        note("Put screenshots online in your own storage (Cloudflare R2, Amazon S3…) and get a link to share. Until this is filled in, Glint never uses the internet.")
                        TextField("Endpoint", text: $model.uploadEndpoint, prompt: Text("https://<account>.r2.cloudflarestorage.com"))
                        TextField("Region", text: $model.uploadRegion, prompt: Text("auto"))
                        TextField("Bucket", text: $model.uploadBucket)
                        TextField("Access key ID", text: $model.uploadAccessKey)
                        SecureField("Secret access key", text: $model.uploadSecret)
                        TextField("Links start with", text: $model.uploadPublicURL, prompt: Text("https://shots.example.com"))
                        Toggle("Hide private info in shared screenshots", isOn: $model.redactBeforeUpload)
                        HStack {
                            Button("Test", action: model.testUpload)
                            if let result = model.uploadTest {
                                Text(result).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 4)
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
