import AppKit
import GlintCore

enum SelectionResult {
    /// `rect` in points, top-left origin of `shot.screen`.
    case area(DisplayShot, CGRect)
    /// `frame`: where the window was, in AppKit global coordinates.
    case window(CGWindowID, frame: CGRect)
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
            // The dim eases in over the frozen screen instead of snapping on.
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            Motion.animate(0.14) { panel.animator().alphaValue = 1 }
            if panel.frame.contains(mouse) {
                panel.makeKey()
                panel.makeFirstResponder(view)
                // Highlight what's under the cursor now, not after the first mouse move.
                view.track(windowPoint: panel.convertPoint(fromScreen: mouse))
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
        guard !panels.isEmpty else { return }  // a key or click during the fade-out
        // A capture fades out under its flying thumbnail. Scrolling and recording set up their
        // capture right away and must not see the overlay, so it goes at once for those.
        for panel in panels {
            if allowsWindowMode, !Motion.reduced {
                panel.ignoresMouseEvents = true
                Motion.animate(0.16, Motion.exit, { panel.animator().alphaValue = 0 }, completion: { panel.orderOut(nil) })
            } else {
                panel.orderOut(nil)
            }
        }
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
    /// Strong: a view outlives `finish()` while its panel fades out and still gets mouse moves
    /// and draws then (tracking areas ignore `ignoresMouseEvents`). `finish()` drops the views,
    /// which breaks the cycle.
    private let overlay: SelectionOverlay
    private var mouse: CGPoint?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    /// The window highlight as drawn: it glides toward the hovered window instead of jumping.
    private var shownWindowFrame: CGRect?
    private var glide: CADisplayLink?
    private let hint = HintBar()

    init(shot: DisplayShot, windows: [PickableWindow], overlay: SelectionOverlay) {
        self.shot = shot
        self.windows = windows
        self.overlay = overlay
        super.init(frame: .zero)
        addSubview(hint)
        hint.alphaValue = 0
    }

    override func layout() {
        super.layout()
        placeHint()
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

    func modeChanged() {
        updateHint()
        retarget()
        needsDisplay = true
    }

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
    override func mouseExited(with event: NSEvent) { mouse = nil; retarget(); updateHint(); needsDisplay = true }
    override func mouseEntered(with event: NSEvent) { window?.makeKey(); window?.makeFirstResponder(self); track(event) }

    private func track(_ event: NSEvent) { track(windowPoint: event.locationInWindow) }

    func track(windowPoint: CGPoint) {
        mouse = convert(windowPoint, from: nil)
        retarget()
        updateHint()
        needsDisplay = true
    }

    // MARK: Window highlight

    /// A press that hasn't moved is still a click on a window, so the highlight stays until a real drag.
    private var isDragging: Bool {
        guard let selection else { return false }
        return selection.width > 3 || selection.height > 3
    }

    private var showsWindowHighlight: Bool { overlay.mode == .window || (overlay.allowsWindowMode && !isDragging) }

    /// Points the highlight at the window under the cursor. The first one appears in place;
    /// after that it glides from window to window.
    private func retarget() {
        let target = showsWindowHighlight ? hoveredWindow?.frame : nil
        guard let target else { shownWindowFrame = nil; stopGlide(); return }
        guard let shown = shownWindowFrame, !Motion.reduced else { shownWindowFrame = target; return }
        if shown != target, glide == nil {
            glide = displayLink(target: self, selector: #selector(glideStep))
            glide?.add(to: .main, forMode: .common)
        }
    }

    @objc private func glideStep() {
        guard let shown = shownWindowFrame, let target = showsWindowHighlight ? hoveredWindow?.frame : nil else { return stopGlide() }
        // Close a fixed share of the gap each frame: fast at first, soft at the end.
        let k: CGFloat = 0.3
        let next = CGRect(x: shown.minX + (target.minX - shown.minX) * k, y: shown.minY + (target.minY - shown.minY) * k,
                          width: shown.width + (target.width - shown.width) * k, height: shown.height + (target.height - shown.height) * k)
        let done = abs(next.minX - target.minX) < 0.5 && abs(next.minY - target.minY) < 0.5
            && abs(next.width - target.width) < 0.5 && abs(next.height - target.height) < 0.5
        shownWindowFrame = done ? target : next
        if done { stopGlide() }
        needsDisplay = true
    }

    private func stopGlide() {
        glide?.invalidate()
        glide = nil
    }

    // MARK: Hint bar

    private func updateHint() {
        let text = overlay.mode == .window
            ? "Click a window  ·  Space: select area  ·  Esc: cancel"
            : overlay.hint + (overlay.allowsWindowMode ? "  ·  Space: windows only" : "") + "  ·  C: copy color  ·  ⏎ full screen  ·  Esc: cancel"
        if hint.text != text { hint.text = text; placeHint() }
        let visible = mouse != nil && !isDragging
        guard visible != (hint.alphaValue > 0.5) else { return }
        Motion.animate(visible ? 0.2 : 0.12, visible ? Motion.settle : Motion.exit) { self.hint.animator().alphaValue = visible ? 1 : 0 }
    }

    private func placeHint() {
        let size = hint.fittingSize
        hint.frame = CGRect(x: (bounds.midX - size.width / 2).rounded(), y: bounds.minY + 44, width: size.width, height: size.height)
    }

    override func mouseDown(with event: NSEvent) {
        // The click itself says where the pointer is; hover tracking can lag or miss
        // (no move yet, or the first move on another display).
        track(event)
        // Window mode picks on press: the matching mouse-up goes to this view even when
        // released on another display, where this screen's windows don't apply.
        if overlay.mode == .window {
            // Only a window counts; a click on the empty desktop does nothing.
            if let window = hoveredWindow { overlay.finish(.window(window.id, frame: shot.screen.globalRect(fromTopLeft: window.frame))) }
            return
        }
        dragStart = mouse
        dragCurrent = mouse
        retarget()
        updateHint()
    }

    override func mouseDragged(with event: NSEvent) {
        guard overlay.mode == .area else { return }
        dragCurrent = convert(event.locationInWindow, from: nil)
        mouse = dragCurrent
        retarget()
        updateHint()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard overlay.mode == .area, dragStart != nil else { return }
        defer { dragStart = nil; dragCurrent = nil }
        if let rect = selection, rect.width > 3, rect.height > 3 {
            overlay.finish(.area(shot, rect))
        } else if let window = hoveredWindow, overlay.allowsWindowMode {
            // A click without a drag takes the window under the cursor, as it is on its own:
            // uncovered, with its shadow and transparent corners. Drag for an area, click for
            // a window, one shortcut for both.
            overlay.finish(.window(window.id, frame: shot.screen.globalRect(fromTopLeft: window.frame)))
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
        // Before a drag starts, the window a click would take is shown, like in window mode.
        let windowHole = showsWindowHighlight
        let hole: CGRect? = windowHole ? shownWindowFrame : selection

        ctx.addRect(bounds)
        if let hole { ctx.addRect(hole) }
        ctx.setFillColor(NSColor.black.withAlphaComponent(windowHole ? 0.25 : 0.35).cgColor)
        ctx.fillPath(using: .evenOdd)

        if let hole {
            if windowHole {
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
            if !isDragging { crosshair(at: mouse, ctx) }
            loupe(at: mouse, ctx)
        }
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

/// The instructions along the top: a HUD pill over a blur of the frozen screen.
private final class HintBar: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
