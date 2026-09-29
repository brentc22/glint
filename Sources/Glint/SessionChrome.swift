import AppKit

/// The on-screen furniture of a running scroll or recording session: a dashed frame
/// around the region (click-through) and a small HUD with a status line and buttons.
/// Both are Glint windows, so ScreenCaptureKit leaves them out of what it captures.
@MainActor
final class SessionChrome {
    let status = NSTextField(labelWithString: "")
    private let frame: NSPanel
    private let hud: NSPanel
    private let icon: NSImageView
    private let pulses: Bool

    init(screen: NSScreen, rect: CGRect, color: NSColor, symbol: String, buttons: [NSButton]) {
        // `rect` is top-left-origin points in `screen`; AppKit windows are bottom-left.
        let global = CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        frame = Self.panel(global.insetBy(dx: -4, dy: -4), clickThrough: true)
        frame.contentView = DashedBorder(color: color)

        let size = CGSize(width: 360, height: 44)
        let below = CGPoint(x: global.midX - size.width / 2, y: global.minY - size.height - 14)
        let inside = CGPoint(x: below.x, y: global.minY + 14)  // full-screen regions have no room outside
        let origin = below.y > screen.visibleFrame.minY ? below : inside
        hud = Self.panel(CGRect(origin: origin, size: size), clickThrough: false)

        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = color
        icon.wantsLayer = true
        pulses = color == .systemRed
        status.textColor = .white
        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        status.lineBreakMode = .byTruncatingTail
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, status] + buttons)
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 10)
        stack.frame = effect.bounds
        stack.autoresizingMask = [.width, .height]
        effect.addSubview(stack)
        hud.contentView = effect
    }

    func show() {
        let home = hud.frame
        frame.alphaValue = 0
        hud.alphaValue = 0
        if !Motion.reduced { hud.setFrame(home.offsetBy(dx: 0, dy: -16), display: false) }
        frame.orderFrontRegardless()
        hud.orderFrontRegardless()
        Motion.move(hud, to: home.origin, spring: .arrive)
        Motion.animate(0.24) {
            self.hud.animator().alphaValue = 1
            self.frame.animator().alphaValue = 1
        }
        // A recording breathes, so it's clear something is running.
        if pulses, !Motion.reduced, let layer = icon.layer {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: "pulse")
        }
    }

    /// The frame goes at once, so the last captured frame can't catch it fading; the HUD eases out.
    func close() {
        frame.orderOut(nil)
        let hud = hud
        Motion.stop(hud)
        Motion.animate(0.2, Motion.exit, { hud.animator().alphaValue = 0 }, completion: { hud.orderOut(nil) })
    }

    private static func panel(_ rect: CGRect, clickThrough: Bool) -> NSPanel {
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = !clickThrough
        p.ignoresMouseEvents = clickThrough
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return p
    }
}

private final class DashedBorder: NSView {
    private let color: NSColor
    init(color: NSColor) { self.color = color; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        color.setStroke()
        path.stroke()
    }
}
