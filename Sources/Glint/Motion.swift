import AppKit
import QuartzCore
import SwiftUI

/// Every animation in Glint takes its timing from here, so the app moves as one thing:
/// short, springy, settling without a bounce — the way macOS's own chrome moves. With
/// Reduce Motion on, movement becomes a plain fade.
@MainActor
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Fast start, long soft landing: reads as a spring without overshooting.
    static let settle = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
    /// Leaving: picks up speed, so the eye isn't asked to follow it out.
    static let exit = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)

    /// SwiftUI's version of `settle`, for hover states and selections.
    static var spring: Animation { reduced ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.86) }
    static var quick: Animation { .easeOut(duration: 0.14) }

    /// Runs AppKit animator changes with Glint's timing.
    static func animate(_ duration: TimeInterval, _ timing: CAMediaTimingFunction = settle,
                        _ changes: @escaping () -> Void, completion: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = timing
            ctx.allowsImplicitAnimation = true
            changes()
        }, completionHandler: completion.map { done in { MainActor.assumeIsolated { done() } } })
    }

    /// A small scale pop on a layer-backed view, around its center: `from` → 1.
    static func pop(_ view: NSView, from scale: CGFloat = 0.94, duration: TimeInterval = 0.32) {
        guard !reduced, let layer = view.layer else { return }
        centerAnchor(layer)
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = scale
        a.toValue = 1
        a.duration = duration
        a.timingFunction = settle
        layer.add(a, forKey: "pop")
    }

    /// Scales a layer toward `scale` (and leaves it there) — the counterpart to `pop` on the way out.
    static func shrink(_ view: NSView, to scale: CGFloat = 0.94, duration: TimeInterval = 0.18) {
        guard !reduced, let layer = view.layer else { return }
        centerAnchor(layer)
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 1
        a.toValue = scale
        a.duration = duration
        a.timingFunction = exit
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        layer.add(a, forKey: "shrink")
    }

    /// Layer-backed views anchor at the bottom-left; scaling should happen around the middle.
    private static func centerAnchor(_ layer: CALayer) {
        guard layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) else { return }
        let frame = layer.frame
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.frame = frame
    }
}

/// Buttons that give under the finger: a slight press-in, like native controls.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
