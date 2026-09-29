@preconcurrency import AVFoundation
import AppKit
import GlintCore

/// On-screen extras that belong *in* a recording — unlike the session's frame and HUD,
/// which the recorder leaves out. Each is its own window, so its ID can be kept in.
@MainActor
protocol RecordingOverlay: AnyObject {
    var windowID: CGWindowID { get }
    func show()
    func close()
}

@MainActor
private func overlayPanel(_ rect: CGRect, clickThrough: Bool) -> NSPanel {
    let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.level = .statusBar
    p.backgroundColor = .clear
    p.isOpaque = false
    p.hasShadow = false
    p.ignoresMouseEvents = clickThrough
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    p.contentView = NSView(frame: CGRect(origin: .zero, size: rect.size))
    p.contentView?.wantsLayer = true
    return p
}

// MARK: - Click rings

/// A ring that grows and fades where you click, so viewers see what was pressed.
/// Mouse clicks elsewhere reach a global monitor without any extra permission.
@MainActor
final class ClickRings: RecordingOverlay {
    private let panel: NSPanel
    private var monitors: [Any] = []

    init(area: CGRect) {
        panel = overlayPanel(area, clickThrough: true)
    }

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    func show() {
        panel.orderFrontRegardless()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.ring(right: event.type == .rightMouseDown) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.ring(right: event.type == .rightMouseDown)
            return event
        }) { monitors.append(local) }
    }

    private func ring(right: Bool) { ring(at: NSEvent.mouseLocation, right: right) }

    /// `point` in AppKit global coordinates.
    func ring(at mouse: CGPoint, right: Bool = false) {
        guard panel.frame.contains(mouse), let root = panel.contentView?.layer else { return }
        let p = CGPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
        let size: CGFloat = 44
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 2, dy: 2), transform: nil)
        let color = right ? NSColor.systemOrange : NSColor.controlAccentColor
        ring.fillColor = color.withAlphaComponent(0.25).cgColor
        ring.strokeColor = color.cgColor
        ring.lineWidth = 3
        ring.opacity = 0
        root.addSublayer(ring)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.4
        grow.toValue = 1.3
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "click")
        CATransaction.commit()
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.orderOut(nil)
    }
}

// MARK: - Keystrokes

/// Shortcuts pressed while recording, as a pill at the bottom of the recorded area.
/// Plain typing is never shown (see `Keystroke`). Seeing other apps' keys needs the
/// Accessibility permission; without it only keys pressed in Glint would show.
@MainActor
final class KeystrokeHUD: RecordingOverlay {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    /// Solid, not vibrant: blur over a bright page turns light grey and the keys wash out.
    private let pill = NSView()
    private var monitors: [Any] = []
    private var hide: DispatchWorkItem?

    init(area: CGRect) {
        let size = CGSize(width: min(area.width, 420), height: 64)
        panel = overlayPanel(CGRect(x: area.midX - size.width / 2, y: area.minY + 28, width: size.width, height: size.height),
                             clickThrough: true)
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor
        pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        pill.layer?.borderWidth = 1
        pill.layer?.cornerRadius = 14
        pill.layer?.cornerCurve = .continuous
        pill.alphaValue = 0
        label.font = .systemFont(ofSize: 26, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        pill.addSubview(label)
        panel.contentView?.addSubview(pill)
    }

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    /// Asks for Accessibility the first time; returns whether keys from other apps will show.
    @discardableResult
    static func requestPermission() -> Bool {
        let prompt = "AXTrustedCheckOptionPrompt" as CFString  // kAXTrustedCheckOptionPrompt, as a literal: it's a global var
        return AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    func show() {
        panel.orderFrontRegardless()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) { monitors.append(local) }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers: Keystroke.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        guard let text = Keystroke.label(keyCode: Int(event.keyCode), characters: event.charactersIgnoringModifiers,
                                         modifiers: modifiers) else { return }
        display(text)
    }

    func display(_ text: String) {
        label.stringValue = text
        label.sizeToFit()
        let bounds = panel.contentView?.bounds ?? .zero
        let width = min(bounds.width, label.frame.width + 40)
        pill.frame = CGRect(x: (bounds.width - width) / 2, y: 6, width: width, height: 52)
        label.frame.origin = CGPoint(x: (width - label.frame.width) / 2, y: (52 - label.frame.height) / 2)
        pill.alphaValue = 1
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Motion.animate(0.25) { self.pill.animator().alphaValue = 0 }
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    func close() {
        hide?.cancel()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.orderOut(nil)
    }
}

// MARK: - Webcam

/// Your camera in a round bubble in the corner of the recording. Drag it anywhere; it
/// records wherever it sits. Mirrored, like every video call.
@MainActor
final class WebcamBubble: RecordingOverlay {
    private let panel: NSPanel
    private let session = AVCaptureSession()

    init?(area: CGRect) {
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return nil }
        session.addInput(input)
        session.sessionPreset = .medium

        let diameter = min(200, min(area.width, area.height) * 0.3)
        let frame = CGRect(x: area.maxX - diameter - 24, y: area.minY + 24, width: diameter, height: diameter)
        panel = overlayPanel(frame, clickThrough: false)
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = CGRect(origin: .zero, size: frame.size)
        preview.connection?.automaticallyAdjustsVideoMirroring = false
        preview.connection?.isVideoMirrored = true
        let root = panel.contentView!.layer!
        root.cornerRadius = diameter / 2
        root.masksToBounds = true
        root.borderWidth = 3
        root.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        root.addSublayer(preview)
    }

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func show() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        Motion.animate(0.25) { self.panel.animator().alphaValue = 1 }
    }

    func close() {
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        panel.orderOut(nil)
    }
}
