import AppKit

/// A screenshot floating above everything — for reference while you type, or to compare
/// two states. Drag to move, pinch or drag the corner to resize, scroll to fade,
/// double-click or Esc to close.
@MainActor
final class PinWindow: NSPanel {
    private static var open: [PinWindow] = []
    private let capture: Capture
    private let onEdit: (Capture) -> Void

    static func pin(_ capture: Capture, onEdit: @escaping (Capture) -> Void) {
        let window = PinWindow(capture, onEdit: onEdit)
        open.append(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(_ capture: Capture, onEdit: @escaping (Capture) -> Void) {
        self.capture = capture
        self.onEdit = onEdit
        let screen = NSScreen.main?.visibleFrame ?? .zero
        var size = capture.pointSize
        let fit = min(1, screen.width * 0.6 / size.width, screen.height * 0.6 / size.height)
        size = CGSize(width: size.width * fit, height: size.height * fit)
        super.init(contentRect: CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                                       width: size.width, height: size.height),
                   styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isMovableByWindowBackground = true
        hasShadow = true
        backgroundColor = .clear
        contentAspectRatio = size
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false

        let view = PinView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.contents = capture.image
        view.layer?.contentsGravity = .resizeAspect
        view.layer?.cornerRadius = 6
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        view.menu = contextMenu()
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        super.close()
        Self.open.removeAll { $0 === self }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        alphaValue = min(1, max(0.2, alphaValue + event.scrollingDeltaY * 0.01))
    }

    override func magnify(with event: NSEvent) {
        var f = frame
        let factor = 1 + event.magnification
        let newSize = CGSize(width: max(80, f.width * factor), height: max(80 * f.height / f.width, f.height * factor))
        f.origin.x -= (newSize.width - f.width) / 2
        f.origin.y -= (newSize.height - f.height) / 2
        f.size = newSize
        setFrame(f, display: true)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { close() } else { super.mouseDown(with: event) }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Annotate", action: #selector(edit), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Save As…", action: #selector(saveAs), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(closePin), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copyImage() { capture.copy(); Toast.show("Copied to clipboard") }
    @objc private func edit() { onEdit(capture); close() }
    @objc private func saveAs() { capture.saveAs() }
    @objc private func closePin() { close() }
}

private final class PinView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
}
