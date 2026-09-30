import AppKit
import GlintCore

/// Checks GitHub Releases once a day and offers to install a newer version, the way
/// Sparkle-based apps do (Install / Later / Skip This Version), without the dependency.
// @MainActor: an `ObservableObject` the settings window reads, driven by timers and
// button actions on the main thread.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let feed = URL(string: "https://api.github.com/repos/brentc22/glint/releases/latest")!
    private let appName = "Glint"
    /// The identity scripts/make-signing-cert.sh creates. When it's in the keychain, an
    /// update is re-signed with it, so the Screen Recording grant survives.
    private let signingIdentity = "Glint Self-Signed"
    private let defaults = UserDefaults.standard
    private enum Key {
        static let automatic = "automaticallyChecksForUpdates"
        static let lastCheck = "lastUpdateCheck"
        static let skipped = "skippedUpdateVersion"
    }

    /// A newer release found by the last check; settings and the menu show it.
    @Published private(set) var available: Release?
    @Published private(set) var isBusy = false
    @Published private(set) var lastCheck: Date?
    @Published var automaticallyChecks: Bool {
        didSet { defaults.set(automaticallyChecks, forKey: Key.automatic) }
    }

    private var timer: Timer?
    private var progress: NSPanel?

    private init() {
        automaticallyChecks = defaults.object(forKey: Key.automatic) as? Bool ?? true
        lastCheck = defaults.object(forKey: Key.lastCheck) as? Date
    }

    var currentVersion: AppVersion {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
            ?? AppVersion("0.0.0")!
    }

    /// Checks shortly after launch and then hourly whether a day has passed since the last check.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer?.tolerance = 5 * 60
    }

    private func checkIfDue() {
        guard automaticallyChecks, UpdatePolicy.isCheckDue(lastCheck: lastCheck) else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                var request = URLRequest(url: feed, timeoutInterval: 20)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let release = try Release.decode(data)
                let now = Date()
                defaults.set(now, forKey: Key.lastCheck)
                lastCheck = now
                let skipped = defaults.string(forKey: Key.skipped)
                let newer = release.version.map { $0 > currentVersion } ?? false
                available = newer ? release : nil
                if UpdatePolicy.shouldOffer(release, current: currentVersion, skipped: skipped, userInitiated: userInitiated) {
                    offer(release)
                } else if userInitiated {
                    inform("You're up to date", "Glint \(currentVersion) is the latest version.")
                }
            } catch {
                NSLog("Glint: update check failed: \(error)")
                if userInitiated {
                    inform("Couldn't check for updates", error.localizedDescription, style: .warning)
                }
            }
        }
    }

    /// Opens the offer again from settings or the menu.
    func offerAvailable() {
        if let available { offer(available) }
    }

    // MARK: - Offer

    private func offer(_ release: Release) {
        guard let version = release.version else { return }
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Glint \(version) is available"
        var text = "You have \(currentVersion). Install it now? Glint restarts by itself afterwards."
        if !UpdateInstaller.hasSigningIdentity(signingIdentity) {
            // Release builds are ad-hoc signed: macOS ties the grant to the binary's hash,
            // so a new version is a new identity and the old grant no longer applies.
            text += "\n\nmacOS will probably ask for Screen Recording permission again. "
                + "Glint opens its settings afterwards to walk you through it."
        }
        alert.informativeText = text
        alert.accessoryView = notesView(release.body)
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release, version: version)
        case .alertThirdButtonReturn:
            defaults.set(version.description, forKey: Key.skipped)
            available = nil
        default: break
        }
    }

    private func notesView(_ body: String?) -> NSView? {
        guard let body, !body.isEmpty else { return nil }
        let notes = (try? NSAttributedString(
            markdown: body,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? NSAttributedString(string: body)
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 380, height: 180)
        scroll.borderType = .bezelBorder
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.textStorage?.setAttributedString(notes)
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.textColor = .labelColor
        return scroll
    }

    // MARK: - Install

    private func install(_ release: Release, version: AppVersion) {
        let destination = Bundle.main.bundleURL
        let parentIsWritable = FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path)
        // From `swift run`, or an /Applications we can't write to: hand over to the browser.
        guard destination.pathExtension == "app", parentIsWritable, let zipURL = release.zipURL(appName: appName) else {
            NSWorkspace.shared.open(release.htmlURL)
            return
        }

        showProgress("Downloading Glint \(version)…")
        Task {
            do {
                let (download, _) = try await URLSession.shared.download(from: zipURL)
                let workDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("GlintUpdate-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                let zip = workDir.appendingPathComponent("\(appName).zip")
                try FileManager.default.moveItem(at: download, to: zip)

                let bundleID = Bundle.main.bundleIdentifier ?? "com.brentc22.Glint"
                let identity = signingIdentity
                let newApp = try await Task.detached {
                    let resign = UpdateInstaller.hasSigningIdentity(identity) ? identity : nil
                    return try UpdateInstaller.prepare(zip: zip, in: workDir, bundleID: bundleID,
                                                       version: version, resignWith: resign)
                }.value

                let script = UpdateInstaller.swapScript(pid: ProcessInfo.processInfo.processIdentifier,
                                                        newApp: newApp, destination: destination)
                let swap = Process()
                swap.executableURL = URL(fileURLWithPath: "/bin/sh")
                swap.arguments = ["-c", script]
                try swap.run()  // outlives us: it waits for this process to exit
                NSApp.terminate(nil)
            } catch {
                hideProgress()
                NSLog("Glint: installing the update failed: \(error)")
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn't install the update"
                alert.informativeText = "\(error.localizedDescription)\n\nYou can also download it yourself from GitHub."
                alert.addButton(withTitle: "Open Download Page")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.htmlURL) }
            }
        }
    }

    private func showProgress(_ message: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 76),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Glint Update"
        let label = NSTextField(labelWithString: message)
        let bar = NSProgressIndicator()
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 260).isActive = true
        panel.contentView = stack
        panel.center()
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        progress = panel
    }

    private func hideProgress() {
        progress?.close()
        progress = nil
    }

    private func inform(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
