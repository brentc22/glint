import AppKit
import GlintCore

enum SelectionResult {
    /// `rect` in points, top-left origin of `shot.screen`.
    case area(DisplayShot, CGRect)
    case window(CGWindowID)
    case cancelled
}

/// Full-screen panels over every display showing the frozen screenshot. Drag for an
/// area, Space to switch to picking a window, Return for the whole screen, Esc to cancel.
@MainActor
final class SelectionOverlay {
    enum Mode { case area, window }

    private var panels: [NSPanel] = []
    private var views: [SelectionView] = []
    private let completion: (SelectionResult) -> Void
    private(set) var mode: Mode
    let allowsWindowMode: Bool
    let hint: String

    init(shots: [DisplayShot], mode: Mode = .area, allowsWindowMode: Bool = true, hint: String,
         completion: @escaping (SelectionResult) -> Void) {
        self.mode = mode
        self.allowsWindowMode = allowsWindowMode
        self.hint = hint
        self.completion = completion
        for shot in shots {
            let panel = OverlayPanel(contentRect: shot.screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.backgroundColor = .clear
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.acceptsMouseMovedEvents = true
            panel.hidesOnDeactivate = false

            let frozen = NSView(frame: CGRect(origin: .zero, size: shot.screen.frame.size))
            frozen.wantsLayer = true
            frozen.layer?.contents = shot.image  // on the GPU; only the overlay redraws on mouse moves
            let view = SelectionView(shot: shot, windows: Capturer.windows(on: shot.screen), overlay: self)
            view.frame = frozen.bounds
            frozen.addSubview(view)
            panel.contentView = frozen
            panel.setFrame(shot.screen.frame, display: false)
            panels.append(panel)
            views.append(view)
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        for (panel, view) in zip(panels, views) {
            panel.orderFrontRegardless()
            if panel.frame.contains(mouse) {
                panel.makeKey()
                panel.makeFirstResponder(view)
            }
        }
        NSCursor.crosshair.set()
    }

    func toggleMode() {
        guard allowsWindowMode else { return }
        mode = mode == .area ? .window : .area
        views.forEach { $0.modeChanged() }
    }

    func finish(_ result: SelectionResult) {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
        completion(result)
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class SelectionView: NSView {
    private let shot: DisplayShot
    private let windows: [PickableWindow]
    private unowned let overlay: SelectionOverlay
    private var mouse: CGPoint?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    init(shot: DisplayShot, windows: [PickableWindow], overlay: SelectionOverlay) {
        self.shot = shot
        self.windows = windows
        self.overlay = overlay
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    func modeChanged() { needsDisplay = true }

    private var selection: CGRect? {
        guard let a = dragStart, let b = dragCurrent else { return nil }
        return CGRect(from: a, to: b).intersection(bounds)
    }

    private var hoveredWindow: PickableWindow? {
        guard let mouse else { return nil }
        return windows.first { $0.frame.contains(mouse) }
    }

    // MARK: Events

    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) { mouse = nil; needsDisplay = true }
    override func mouseEntered(with event: NSEvent) { window?.makeKey(); window?.makeFirstResponder(self); track(event) }

    private func track(_ event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p
        dragCurrent = p
    }

    override func mouseDragged(with event: NSEvent) {
        guard overlay.mode == .area else { return }
        dragCurrent = convert(event.locationInWindow, from: nil)
        mouse = dragCurrent
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragCurrent = nil }
        if overlay.mode == .area, let rect = selection, rect.width > 3, rect.height > 3 {
            overlay.finish(.area(shot, rect))
        } else if let window = hoveredWindow, overlay.allowsWindowMode {
            // A click without a drag picks the window under the cursor.
            overlay.finish(overlay.mode == .window ? .window(window.id) : .area(shot, window.frame.intersection(bounds)))
        } else {
            overlay.finish(.area(shot, bounds))
        }
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: overlay.finish(.cancelled)                 // Esc
        case 49: overlay.toggleMode()                       // Space
        case 36, 76: overlay.finish(.area(shot, bounds))    // Return: whole screen
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "c", let mouse,
               let hex = hexColor(at: CGPoint(x: (mouse.x * shot.scale).rounded(.down), y: (mouse.y * shot.scale).rounded(.down))) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hex, forType: .string)
                overlay.finish(.cancelled)
                Toast.show("Copied \(hex)", symbol: "eyedropper")
            } else {
                super.keyDown(with: event)
            }
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let hole: CGRect? = overlay.mode == .window ? hoveredWindow?.frame : selection

        ctx.addRect(bounds)
        if let hole { ctx.addRect(hole) }
        ctx.setFillColor(NSColor.black.withAlphaComponent(overlay.mode == .window ? 0.25 : 0.35).cgColor)
        ctx.fillPath(using: .evenOdd)

        if let hole {
            if overlay.mode == .window {
                ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor)
                ctx.fill(hole)
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                ctx.setLineWidth(3)
            } else {
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(1)
            }
            ctx.stroke(hole.insetBy(dx: 0.5, dy: 0.5))
            label("\(Int(hole.width * shot.scale)) × \(Int(hole.height * shot.scale))", below: hole)
        }

        if overlay.mode == .area, let mouse {
            if selection == nil { crosshair(at: mouse, ctx) }
            loupe(at: mouse, ctx)
        }
        if mouse != nil, selection == nil { hintBar() }
    }

    private func crosshair(at p: CGPoint, _ ctx: CGContext) {
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 4])
        ctx.strokeLineSegments(between: [CGPoint(x: 0, y: p.y.rounded() + 0.5), CGPoint(x: bounds.maxX, y: p.y.rounded() + 0.5),
                                         CGPoint(x: p.x.rounded() + 0.5, y: 0), CGPoint(x: p.x.rounded() + 0.5, y: bounds.maxY)])
        ctx.setLineDash(phase: 0, lengths: [])
    }

    /// 8× magnified pixels around the cursor, for pixel-exact edges.
    private func loupe(at p: CGPoint, _ ctx: CGContext) {
        let size: CGFloat = 120, pixels = 15
        let px = CGPoint(x: (p.x * shot.scale).rounded(.down), y: (p.y * shot.scale).rounded(.down))
        let source = CGRect(x: px.x - CGFloat(pixels / 2), y: px.y - CGFloat(pixels / 2), width: CGFloat(pixels), height: CGFloat(pixels))
        guard let patch = shot.image.cropping(to: source) else { return }

        var origin = CGPoint(x: p.x + 24, y: p.y + 24)
        if origin.x + size > bounds.maxX { origin.x = p.x - 24 - size }
        if origin.y + size + 28 > bounds.maxY { origin.y = p.y - 24 - size - 28 }
        let frame = CGRect(origin: origin, size: CGSize(width: size, height: size))

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 12, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.clip()
        ctx.interpolationQuality = .none
        Renderer.drawImage(patch, in: frame, ctx)
        let cell = size / CGFloat(pixels)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(CGRect(x: frame.midX - cell / 2, y: frame.midY - cell / 2, width: cell, height: cell))
        ctx.restoreGState()

        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2)
        ctx.strokePath()

        pill("\(Int(px.x)), \(Int(px.y))  \(hexColor(at: px) ?? "")",
             at: CGPoint(x: frame.midX, y: frame.maxY + 16))
    }

    private func hexColor(at px: CGPoint) -> String? {
        guard let one = shot.image.cropping(to: CGRect(origin: px, size: CGSize(width: 1, height: 1))) else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        guard let c = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return String(format: "#%02X%02X%02X", rgba[0], rgba[1], rgba[2])
    }

    private func label(_ text: String, below rect: CGRect) {
        var y = rect.maxY + 16
        if y + 12 > bounds.maxY { y = rect.maxY - 18 }
        pill(text, at: CGPoint(x: rect.midX, y: y))
    }

    private func hintBar() {
        let text = overlay.mode == .window
            ? "Click a window  ·  Space: select area  ·  Esc: cancel"
            : overlay.hint + (overlay.allowsWindowMode ? "  ·  Space: pick window" : "") + "  ·  C: copy color  ·  ⏎ full screen  ·  Esc: cancel"
        pill(text, at: CGPoint(x: bounds.midX, y: bounds.minY + 60), size: 13)
    }

    private func pill(_ text: String, at center: CGPoint, size: CGFloat = 11) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let box = CGRect(x: center.x - textSize.width / 2 - 8, y: center.y - textSize.height / 2 - 3,
                         width: textSize.width + 16, height: textSize.height + 6)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        string.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 3))
    }
}
