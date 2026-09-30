import AVFoundation
import AppKit
import GlintCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hotKeys = HotKeys()
    private var overlay: SelectionOverlay?
    private var scrollSession: ScrollSession?
    private var recording: RecordingSession?
    private lazy var quickAccess = QuickAccess(actions: CaptureActions(
        edit: { [weak self] in self?.edit($0) },
        pin: { [weak self] in self?.pin($0) },
        redact: { [weak self] in self?.redact($0) },
        copyText: { capture in Task { await Self.copyText(of: capture.image) } },
        makeGIF: { capture in Task { await Self.makeGIF(capture) } },
        trim: { TrimWindow.show($0) },
        upload: { Uploader.share($0) }))
    /// Last area selection, for "Capture Previous Area".
    private var lastArea: (display: CGDirectDisplayID, rect: CGRect)?

    func run(_ command: CaptureCommand) {
        switch command {
        case .area: select(.area)
        case .window: select(.window)
        case .fullScreen: captureFullScreen()
        case .previousArea: capturePreviousArea()
        case .scrolling: if let scrollSession { scrollSession.done() } else { select(.area, purpose: .scrolling) }
        case .text: select(.area, purpose: .text)
        case .recording: if let recording { recording.stop() } else { select(.area, purpose: .recording) }
        }
    }

    /// (Re)binds every command's shortcut; the Shortcuts settings call this after a change.
    /// Returns the commands whose shortcut another app (or macOS itself) already owns.
    @discardableResult
    func registerShortcuts() -> [CaptureCommand] {
        hotKeys.unregisterAll()
        let system = SystemShortcuts.enabledScreenshotCombos()
        return CaptureCommand.allCases.filter { command in
            guard let combo = command.shortcut else { return false }
            let registered = hotKeys.register(combo) { [weak self] in self?.run(command) }
            return !registered || system.contains(combo)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if CommandLine.arguments.contains("--self-test") {
            Task { await SelfTest.run() }
            return
        }
        registerShortcuts()
        Updater.shared.start()
        showSettingsIfUpdateLostPermission()

        // `--edit <image>` and `--quick-access <image>` open an existing image straight
        // into the editor or the overlay — for development and README screenshots,
        // without needing a capture (or the Screen Recording permission).
        let args = CommandLine.arguments
        for flag in ["--edit", "--quick-access"] {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count,
                  let capture = Self.load(URL(fileURLWithPath: args[i + 1]), keepFile: false) else { continue }
            flag == "--edit" ? edit(capture) : quickAccess.show(capture, on: NSScreen.main)
        }
        // `--settings <tab>` opens the settings on that tab (0-based), for screenshots.
        if let i = args.firstIndex(of: "--settings") {
            let tab = i + 1 < args.count ? Int(args[i + 1]) : nil
            SettingsWindow.show(tab: tab) { [weak self] in self?.registerShortcuts() ?? [] }
        }
        if args.contains("--history") { openHistory() }
        // `--trim <video>`: the trim window on that recording.
        if let i = args.firstIndex(of: "--trim"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            Task {
                guard let frame = try? await AVAssetImageGenerator(asset: AVURLAsset(url: url)).image(at: .zero).image else { return }
                TrimWindow.show(Capture(image: frame, scale: 2, file: url))
            }
        }
        // `--select-demo <image>`: the selection overlay over that image instead of a real
        // screen grab — exercises the whole capture flow without the permission.
        if let i = args.firstIndex(of: "--select-demo"), i + 1 < args.count, let screen = NSScreen.main,
           let demo = Self.load(URL(fileURLWithPath: args[i + 1]), keepFile: false) {
            let s = screen.backingScaleFactor
            let size = CGSize(width: screen.frame.width * s, height: screen.frame.height * s)
            let backdrop = Renderer.draw(size: size) { ctx in
                ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
                ctx.fill(CGRect(origin: .zero, size: size))
                let aspect = CGFloat(demo.image.height) / CGFloat(demo.image.width)
                let w = min(size.width * 0.8, size.height * 0.8 / aspect), h = w * aspect
                Renderer.drawImage(demo.image, in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h), ctx)
            }
            if let backdrop { showOverlay([DisplayShot(screen: screen, image: backdrop)], mode: .area, purpose: .capture) }
        }
    }

    /// A release build is ad-hoc signed, and macOS ties the Screen Recording grant to the
    /// old binary's signature. Right after an update that lost it, open the General tab,
    /// whose banner links to System Settings. The swap script relaunches with `--after-update`.
    private func showSettingsIfUpdateLostPermission() {
        guard CommandLine.arguments.contains("--after-update") else { return }
        Task {
            guard !(await Capturer.hasPermission()) else { return }
            SettingsWindow.show(tab: 0) { [weak self] in self?.registerShortcuts() ?? [] }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let version = Updater.shared.available?.version {
            menu.addItem(item("Update Available: Glint \(version)…", #selector(showUpdate), symbol: "arrow.down.circle.fill"))
            menu.addItem(.separator())
        }
        for command in CaptureCommand.allCases {
            let item = NSMenuItem(title: command.title, action: #selector(runCommand(_:)), keyEquivalent: command.shortcut?.keyEquivalent ?? "")
            item.keyEquivalentModifierMask = command.shortcut?.modifiers ?? []
            item.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil)
            item.representedObject = command.rawValue
            item.target = self
            menu.addItem(item)
        }
        let timer = NSMenuItem(title: "Capture with Timer", action: nil, keyEquivalent: "")
        timer.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        timer.submenu = NSMenu()
        for seconds in [3, 5, 10] {
            let t = NSMenuItem(title: "\(seconds) seconds", action: #selector(captureWithTimer(_:)), keyEquivalent: "")
            t.tag = seconds
            t.target = self
            timer.submenu?.addItem(t)
        }
        menu.addItem(timer)
        menu.addItem(.separator())
        let clipboard = item("Annotate Clipboard Image", #selector(annotateClipboard), symbol: "doc.on.clipboard")
        clipboard.isEnabled = NSImage(pasteboard: .general) != nil
        menu.addItem(clipboard)
        menu.addItem(item("Open Image…", #selector(openImage), symbol: "photo"))
        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        recent.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        recent.submenu = recentMenu()
        menu.addItem(recent)
        menu.addItem(item("Capture History…", #selector(openHistory), key: "h", symbol: "square.grid.2x2"))
        menu.addItem(item("Show Screenshots Folder", #selector(openFolder), symbol: "folder"))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ",", symbol: "gearshape"))
        menu.addItem(NSMenuItem(title: "Quit Glint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func recentMenu() -> NSMenu {
        let menu = NSMenu()
        let files = (try? FileManager.default.contentsOfDirectory(at: Prefs.saveFolder, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { modified($0) > modified($1) }
            .prefix(10) ?? []
        if files.isEmpty {
            menu.addItem(withTitle: "No screenshots yet", action: nil, keyEquivalent: "").isEnabled = false
        }
        for file in files {
            let item = NSMenuItem(title: file.deletingPathExtension().lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = file
            if let thumb = NSImage(contentsOf: file) {
                thumb.size = CGSize(width: 32, height: 32 * thumb.size.height / max(thumb.size.width, 1))
                item.image = thumb
            }
            menu.addItem(item)
        }
        return menu
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let command = (sender.representedObject as? String).flatMap(CaptureCommand.init) else { return }
        // Let the menu close first, or it ends up in the frozen screenshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.run(command) }
    }

    /// Counts down, then freezes the screen — time to open a menu or hover a button.
    @objc private func captureWithTimer(_ sender: NSMenuItem) {
        let seconds = sender.tag
        for i in 0..<seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(i)) {
                Toast.show("\(seconds - i)", symbol: "timer")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { self.select(.area) }
    }

    @objc private func annotateClipboard() {
        guard let image = NSImage(pasteboard: .general),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let scale = max(1, (CGFloat(cg.width) / max(image.size.width, 1)).rounded())
        edit(Capture(image: cg, scale: scale))
    }

    @objc private func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let capture = Self.load(url, keepFile: false) else { return }
        edit(capture)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let capture = Self.load(url, keepFile: true) else { return }
        edit(capture)
    }

    @objc private func openHistory() {
        HistoryWindow.show(open: { [weak self] url in
            // Videos and GIFs open in their own app; the editor takes stills.
            guard !["mp4", "gif"].contains(url.pathExtension.lowercased()), let capture = Self.load(url, keepFile: true) else {
                NSWorkspace.shared.open(url)
                return
            }
            self?.edit(capture)
        }, pin: { [weak self] url in
            if let capture = Self.load(url, keepFile: true) { self?.pin(capture) }
        })
    }

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: Prefs.saveFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Prefs.saveFolder)
    }

    @objc private func showUpdate() { Updater.shared.offerAvailable() }

    @objc private func openSettings() {
        SettingsWindow.show(onShortcutsChanged: { [weak self] in self?.registerShortcuts() ?? [] })
    }

    /// The logo's lens and glint as a template image, so the menu bar tints it.
    private static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 1.6
            NSColor.black.setStroke()
            ring.stroke()
            let c = NSPoint(x: rect.midX + 0.5, y: rect.midY + 0.5), r: CGFloat = 5, k: CGFloat = 0.9
            let star = NSBezierPath()
            star.move(to: NSPoint(x: c.x, y: c.y + r))
            star.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + k, y: c.y + k), controlPoint2: NSPoint(x: c.x + k, y: c.y + k))
            star.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + k, y: c.y - k), controlPoint2: NSPoint(x: c.x + k, y: c.y - k))
            star.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - k, y: c.y - k), controlPoint2: NSPoint(x: c.x - k, y: c.y - k))
            star.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - k, y: c.y + k), controlPoint2: NSPoint(x: c.x - k, y: c.y + k))
            NSColor.black.setFill()
            star.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Glint"
        return image
    }()

    /// Reads an image and recovers its Retina scale from the DPI Glint wrote (144 → 2×).
    private static func load(_ url: URL, keepFile: Bool) -> Capture? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = props?[kCGImagePropertyDPIWidth] as? CGFloat ?? 72
        return Capture(image: image, scale: max(1, (dpi / 72).rounded()), file: keepFile ? url : nil)
    }

    // MARK: Capture flows

    /// What an area selection is for.
    private enum Purpose {
        case capture, text, scrolling, recording

        var hint: String {
            switch self {
            case .capture: "Drag for an area, click for a window"
            case .text: "Drag over text or a QR code to copy it"
            case .scrolling: "Select the part that scrolls"
            case .recording: "Select what to record"
            }
        }
    }

    private func select(_ mode: SelectionOverlay.Mode, purpose: Purpose = .capture) {
        guard overlay == nil, scrollSession == nil, recording == nil else { return }
        Task {
            guard await Permission.ensure(), overlay == nil else { return }
            do {
                showOverlay(try await Capturer.captureDisplays(), mode: mode, purpose: purpose)
            } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    private func showOverlay(_ shots: [DisplayShot], mode: SelectionOverlay.Mode, purpose: Purpose) {
        let overlay = SelectionOverlay(shots: shots, mode: mode, allowsWindowMode: purpose == .capture, hint: purpose.hint) { result in
            // The app delegate lives as long as the app; no retain cycle to break.
            self.overlay = nil
            self.handle(result, purpose: purpose)
        }
        self.overlay = overlay
        overlay.show()
    }

    private func handle(_ result: SelectionResult, purpose: Purpose) {
        switch result {
        case let .area(shot, rect):
            let pixels = CGRect(x: rect.minX * shot.scale, y: rect.minY * shot.scale,
                                width: rect.width * shot.scale, height: rect.height * shot.scale).integral
            // Only `screen` goes into the session closures: a whole DisplayShot would keep
            // the full frozen frame alive for as long as a recording runs.
            let screen = shot.screen
            switch purpose {
            case .text:
                guard let image = Renderer.crop(shot.image, to: pixels) else { return }
                Task { await Self.copyText(of: image) }
            case .scrolling:
                let session = ScrollSession(screen: screen, rect: rect) { [weak self] capture in
                    self?.scrollSession = nil
                    if let capture { self?.finish(capture, screen: screen) }
                }
                scrollSession = session
                session.start()
            case .recording:
                let session = RecordingSession(screen: screen, rect: rect) { [weak self] capture in
                    self?.recording = nil
                    if let capture { self?.finishRecording(capture, screen: screen) }
                }
                recording = session
                session.start()
            case .capture:
                guard let image = Renderer.crop(shot.image, to: pixels) else { return }
                if let id = shot.screen.displayID { lastArea = (id, rect) }
                finish(Capture(image: image, scale: shot.scale), screen: shot.screen,
                       from: shot.screen.globalRect(fromTopLeft: rect))
            }
        case let .window(id, frame):
            Task {
                do {
                    let (image, scale) = try await Capturer.captureWindow(id)
                    let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
                    finish(Capture(window: image, scale: scale), screen: screen, from: frame)
                } catch {
                    Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
                }
            }
        case .cancelled:
            break
        }
    }

    private func captureFullScreen() {
        Task {
            guard await Permission.ensure(), let shots = try? await Capturer.captureDisplays() else { return }
            let mouse = NSEvent.mouseLocation
            guard let shot = shots.first(where: { $0.screen.frame.contains(mouse) }) ?? shots.first else { return }
            finish(Capture(image: shot.image, scale: shot.scale), screen: shot.screen, from: shot.screen.frame)
        }
    }

    private func capturePreviousArea() {
        guard let last = lastArea else { return select(.area) }
        Task {
            guard await Permission.ensure(), let shots = try? await Capturer.captureDisplays(),
                  let shot = shots.first(where: { $0.screen.displayID == last.display }) else { return }
            handle(.area(shot, last.rect), purpose: .capture)
        }
    }

    /// `from`: where the capture was on screen, so its thumbnail can fly out of it.
    private func finish(_ capture: Capture, screen: NSScreen?, from source: CGRect? = nil) {
        Capture.playShutter()
        Task {
            if Prefs.autoRedact { _ = await Self.redactInPlace(capture) }
            if Prefs.autoSave { _ = try? capture.save(); HistoryWindow.refresh() }
            if Prefs.copyToClipboard { capture.copy() }
            if Prefs.openEditor { edit(capture) } else if Prefs.showQuickAccess { quickAccess.show(capture, on: screen, from: source) }
        }
    }

    /// Recordings skip what only makes sense for stills: redaction, the editor, image copy.
    private func finishRecording(_ capture: Capture, screen: NSScreen?) {
        HistoryWindow.refresh()
        if Prefs.copyToClipboard { capture.copy() }
        quickAccess.show(capture, on: screen)
    }

    private static func makeGIF(_ capture: Capture) async {
        guard let video = capture.file else { return }
        Toast.show("Making GIF…", symbol: "photo.stack")
        do {
            let gif = try await GIFExport.make(from: video)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([gif as NSURL])
            Toast.show("GIF saved and copied", symbol: "photo.stack.fill")
        } catch {
            Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        }
    }

    // MARK: Capture actions

    private func edit(_ capture: Capture) {
        EditorWindow.show(capture) { [weak self] in self?.pin($0) }
    }

    private func pin(_ capture: Capture) {
        PinWindow.pin(capture) { [weak self] in self?.edit($0) }
    }

    private func redact(_ capture: Capture) {
        Task {
            let count = await Self.redactInPlace(capture)
            Toast.show(count == 0 ? "Nothing sensitive found" : "Redacted \(count) item\(count == 1 ? "" : "s")",
                       symbol: count == 0 ? "checkmark.shield" : "eye.slash.fill")
        }
    }

    private static func redactInPlace(_ capture: Capture) async -> Int {
        let regions = await TextRecognizer.sensitiveRegions(in: capture.image, kinds: Prefs.redactKinds, customTerms: Prefs.customTerms)
        guard !regions.isEmpty,
              let redacted = Renderer.render(capture.image, annotations: regions.map { Annotation(Prefs.redactStyle.kind($0)) })
        else { return 0 }
        capture.update(redacted)
        return regions.count
    }

    /// QR codes win over text: scanning one almost always means you want its link.
    private static func copyText(of image: CGImage) async {
        if let code = await TextRecognizer.barcodes(in: image).first {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            return Toast.show(code.count > 40 ? "Copied QR code" : "Copied \(code)", symbol: "qrcode")
        }
        let text = await TextRecognizer.text(in: image)
        guard !text.isEmpty else { return Toast.show("No text found", symbol: "text.magnifyingglass") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.show("Copied \(text.split(whereSeparator: \.isWhitespace).count) words", symbol: "text.viewfinder")
    }
}
