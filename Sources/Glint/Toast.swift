import AppKit

/// A short HUD message low in the middle of the screen — "Copied 42 words". Pops in and
/// fades away like the volume and brightness HUDs.
@MainActor
enum Toast {
    private static var panel: NSPanel?

    static func show(_ message: String, symbol: String = "checkmark.circle.fill") {
        if let old = panel { dismiss(old, duration: 0.1) }
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        icon.contentTintColor = .white
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 22)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor), stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor), stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        // Clear room around the HUD, so the pop's overshoot isn't cut off at the window edge.
        let pad: CGFloat = 16
        let size = stack.fittingSize
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let p = NSPanel(contentRect: CGRect(x: screen.midX - size.width / 2 - pad, y: screen.minY + screen.height * 0.18 - pad,
                                            width: size.width + 2 * pad, height: size.height + 2 * pad),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        // The pop scales the HUD inside a still container: AppKit owns the root view's layer.
        let container = NSView(frame: CGRect(origin: .zero, size: CGSize(width: size.width + 2 * pad, height: size.height + 2 * pad)))
        effect.frame = container.bounds.insetBy(dx: pad, dy: pad)
        effect.autoresizingMask = [.width, .height]
        container.addSubview(effect)
        p.contentView = container
        p.alphaValue = 0
        p.orderFrontRegardless()
        panel = p
        Motion.pop(effect, from: 0.86)
        Motion.animate(0.18) { p.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if panel === p { dismiss(p, duration: 0.28) }
        }
    }

    private static func dismiss(_ p: NSPanel, duration: TimeInterval) {
        if panel === p { panel = nil }
        if let view = p.contentView?.subviews.first { Motion.shrink(view, to: 0.96, duration: duration) }
        Motion.animate(duration, Motion.exit, { p.animator().alphaValue = 0 }, completion: { p.orderOut(nil) })
    }
}
