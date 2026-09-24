import AppKit
import Carbon.HIToolbox
import GlintCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hotKeys = HotKeys()
    private var overlay: SelectionOverlay?
    private lazy var quickAccess = QuickAccess(actions: CaptureActions(
        edit: { [weak self] in self?.edit($0) },
        pin: { [weak self] in self?.pin($0) },
        redact: { [weak self] in self?.redact($0) },
        copyText: { capture in Task { await Self.copyText(of: capture.image) } }))
    /// Last area selection, for "Capture Previous Area".
    private var lastArea: (display: CGDirectDisplayID, rect: CGRect)?

    private struct Action {
        let title: String
        let symbol: String
        let combo: HotKeys.Combo
        let run: (AppDelegate) -> Void
    }

    private let actions: [Action] = [
        Action(title: "Capture Area", symbol: "rectangle.dashed", combo: .init(keyCode: kVK_ANSI_4, modifiers: [.control, .shift])) { $0.select(.area) },
        Action(title: "Capture Window", symbol: "macwindow", combo: .init(keyCode: kVK_ANSI_5, modifiers: [.control, .shift])) { $0.select(.window) },
        Action(title: "Capture Full Screen", symbol: "display", combo: .init(keyCode: kVK_ANSI_3, modifiers: [.control, .shift])) { $0.captureFullScreen() },
        Action(title: "Capture Previous Area", symbol: "arrow.counterclockwise.circle", combo: .init(keyCode: kVK_ANSI_6, modifiers: [.control, .shift])) { $0.capturePreviousArea() },
        Action(title: "Capture Text", symbol: "text.viewfinder", combo: .init(keyCode: kVK_ANSI_2, modifiers: [.control, .shift])) { $0.select(.area, forText: true) },
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Glint")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        for action in actions {
            hotKeys.register(action.combo) { [weak self] in if let self { action.run(self) } }
        }

        // `--edit <image>` and `--quick-access <image>` open an existing image straight
        // into the editor or the overlay — for development and README screenshots,
        // without needing a capture (or the Screen Recording permission).
        let args = CommandLine.arguments
        for flag in ["--edit", "--quick-access"] {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count,
                  let capture = Self.load(URL(fileURLWithPath: args[i + 1]), keepFile: false) else { continue }
            flag == "--edit" ? edit(capture) : quickAccess.show(capture, on: NSScreen.main)
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
            if let backdrop { showOverlay([DisplayShot(screen: screen, image: backdrop)], mode: .area, forText: false) }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for (i, action) in actions.enumerated() {
            let item = NSMenuItem(title: action.title, action: #selector(runAction(_:)), keyEquivalent: action.combo.keyEquivalent)
            item.keyEquivalentModifierMask = action.combo.modifiers
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            item.tag = i
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(item("Open Image…", #selector(openImage), symbol: "photo"))
        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        recent.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        recent.submenu = recentMenu()
        menu.addItem(recent)
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

    @objc private func runAction(_ sender: NSMenuItem) {
        // Let the menu close first, or it ends up in the frozen screenshot.
        let action = actions[sender.tag]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { action.run(self) }
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

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: Prefs.saveFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Prefs.saveFolder)
    }

    @objc private func openSettings() {
        SettingsWindow.show(shortcuts: actions.map { ($0.title, $0.combo.symbol) })
    }

    /// Reads an image and recovers its Retina scale from the DPI Glint wrote (144 → 2×).
    private static func load(_ url: URL, keepFile: Bool) -> Capture? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = props?[kCGImagePropertyDPIWidth] as? CGFloat ?? 72
        return Capture(image: image, scale: max(1, (dpi / 72).rounded()), file: keepFile ? url : nil)
    }

    // MARK: Capture flows

    private func select(_ mode: SelectionOverlay.Mode, forText: Bool = false) {
        guard overlay == nil, Permission.ensure() else { return }
        Task {
            do {
                showOverlay(try await Capturer.captureDisplays(), mode: mode, forText: forText)
            } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    private func showOverlay(_ shots: [DisplayShot], mode: SelectionOverlay.Mode, forText: Bool) {
        let overlay = SelectionOverlay(shots: shots, mode: mode, allowsWindowMode: !forText,
                                       hint: forText ? "Drag over text to copy it" : "Drag to capture") { result in
            // The app delegate lives as long as the app; no retain cycle to break.
            self.overlay = nil
            self.handle(result, forText: forText)
        }
        self.overlay = overlay
        overlay.show()
    }

    private func handle(_ result: SelectionResult, forText: Bool) {
        switch result {
        case let .area(shot, rect):
            let pixels = CGRect(x: rect.minX * shot.scale, y: rect.minY * shot.scale,
                                width: rect.width * shot.scale, height: rect.height * shot.scale).integral
            guard let image = shot.image.cropping(to: pixels) else { return }
            if let id = shot.screen.displayID { lastArea = (id, rect) }
            if forText {
                Task { await Self.copyText(of: image) }
            } else {
                finish(Capture(image: image, scale: shot.scale), screen: shot.screen)
            }
        case let .window(id):
            Task {
                do {
                    let (image, scale) = try await Capturer.captureWindow(id)
                    finish(Capture(image: image, scale: scale), screen: NSScreen.main)
                } catch {
                    Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
                }
            }
        case .cancelled:
            break
        }
    }

    private func captureFullScreen() {
        guard Permission.ensure() else { return }
        Task {
            guard let shots = try? await Capturer.captureDisplays() else { return }
            let mouse = NSEvent.mouseLocation
            guard let shot = shots.first(where: { $0.screen.frame.contains(mouse) }) ?? shots.first else { return }
            finish(Capture(image: shot.image, scale: shot.scale), screen: shot.screen)
        }
    }

    private func capturePreviousArea() {
        guard let last = lastArea else { return select(.area) }
        guard Permission.ensure() else { return }
        Task {
            guard let shots = try? await Capturer.captureDisplays(),
                  let shot = shots.first(where: { $0.screen.displayID == last.display }) else { return }
            handle(.area(shot, last.rect), forText: false)
        }
    }

    private func finish(_ capture: Capture, screen: NSScreen?) {
        Capture.playShutter()
        Task {
            if Prefs.autoRedact { _ = await Self.redactInPlace(capture) }
            if Prefs.autoSave { _ = try? capture.save() }
            if Prefs.copyToClipboard { capture.copy() }
            if Prefs.showQuickAccess { quickAccess.show(capture, on: screen) }
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
        let regions = await TextRecognizer.sensitiveRegions(in: capture.image)
        guard !regions.isEmpty,
              let redacted = Renderer.render(capture.image, annotations: regions.map { Annotation(.pixelate($0)) })
        else { return 0 }
        capture.update(redacted)
        return regions.count
    }

    private static func copyText(of image: CGImage) async {
        let text = await TextRecognizer.text(in: image)
        guard !text.isEmpty else { return Toast.show("No text found", symbol: "text.magnifyingglass") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.show("Copied \(text.split(whereSeparator: \.isWhitespace).count) words", symbol: "text.viewfinder")
    }
}
