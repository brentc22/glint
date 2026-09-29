import AppKit
import QuartzCore
import SwiftUI

/// Every animation in Glint takes its timing from here, so the app moves as one thing:
/// real springs — windows on a display-link spring that keeps its velocity when retargeted,
/// layers on `CASpringAnimation` — the way macOS's own chrome moves. With Reduce Motion
/// on — or motion off in Settings → Motion — movement becomes a plain fade. Speed and bounce
/// from Settings are applied here, so every animation follows them.
@MainActor
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !Prefs.motionEnabled }
    /// Settings → Motion → Speed, as a factor on durations.
    /// Fades-only mode (motion off, Reduce Motion) keeps standard timing: its pickers are greyed out.
    static var pace: Double { reduced ? 1 : Prefs.motionSpeed.scale }

    /// Fast start, long soft landing: reads as a spring without overshooting.
    static let settle = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
    /// Leaving: picks up speed, so the eye isn't asked to follow it out.
    static let exit = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)

    /// A spring in SwiftUI's terms: `response` is roughly how long it takes, `bounce` 0 settles
    /// without overshoot, 0.2 lands with a visible little give.
    struct Spring {
        let response: Double
        let bounce: Double
        /// With the user's speed and bounce applied. Bounce stays under 0.6: past that a
        /// spring wobbles instead of landing.
        @MainActor var tuned: Spring { Spring(response: response * Motion.pace, bounce: min(0.6, bounce * Prefs.motionBounce.scale)) }
        /// Moves that make room or come back: quick, no overshoot to distract.
        static let glide = Spring(response: 0.36, bounce: 0.04)
        /// Things arriving — a card, a HUD: lands with a hint of give.
        static let arrive = Spring(response: 0.46, bounce: 0.16)
        /// Pops in place (toast, pin): a livelier scale.
        static let pop = Spring(response: 0.38, bounce: 0.3)
        /// Leaving over an edge: stiff, so it's gone before the eye follows.
        static let leave = Spring(response: 0.28, bounce: 0)
    }

    /// SwiftUI's version, for hover states and selections.
    static var spring: Animation {
        let s = Spring(response: 0.3, bounce: 0.12).tuned
        return reduced ? .easeOut(duration: 0.12) : .spring(response: s.response, dampingFraction: 1 - s.bounce)
    }
    static var quick: Animation { .easeOut(duration: 0.14 * pace) }

    /// Runs AppKit animator changes with Glint's timing.
    static func animate(_ duration: TimeInterval, _ timing: CAMediaTimingFunction = settle,
                        _ changes: @escaping () -> Void, completion: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration * pace
            ctx.timingFunction = timing
            ctx.allowsImplicitAnimation = true
            changes()
        }, completionHandler: completion.map { done in { MainActor.assumeIsolated { done() } } })
    }

    /// A small scale pop on a layer-backed view, around its center: `from` → 1.
    static func pop(_ view: NSView, from scale: CGFloat = 0.9, spring: Spring = .pop) {
        guard !reduced, let layer = view.layer else { return }
        centerAnchor(layer)
        layer.add(springAnimation("transform.scale", from: scale, to: 1, spring), forKey: "pop")
    }

    /// A `CASpringAnimation` from `from` to `to`; the caller sets the model value to `to`.
    /// Cut at the point where what's left of the spring is under a pixel, not its full tail.
    static func springAnimation(_ keyPath: String, from: Any?, to: Any?, _ spring: Spring) -> CASpringAnimation {
        let spring = spring.tuned
        let a = CASpringAnimation(perceptualDuration: spring.response, bounce: spring.bounce)
        a.keyPath = keyPath
        a.fromValue = from
        a.toValue = to
        a.duration = min(a.settlingDuration, spring.response * (1.6 + 3 * spring.bounce))
        return a
    }

    /// Moves a window's origin along `spring`, one display frame at a time. A window that's
    /// already moving keeps its velocity and bends toward the new target — no stop-and-restart
    /// when a card is pushed twice. `velocity` (points/s) carries a flick into the move.
    static func move(_ window: NSWindow, to origin: CGPoint, spring: Spring = .glide, velocity: CGVector? = nil) {
        let key = ObjectIdentifier(window)
        // A mover left behind by a window that's gone must not steer a new one at the same address.
        if let stale = WindowSpring.running[key], stale.window !== window { stop(key) }
        let mover: WindowSpring
        if let running = WindowSpring.running[key] {
            mover = running
        } else if !reduced,
                  // The destination display's link: a card sliding in from the edge starts on no
                  // display at all, where its own view's link would never fire.
                  let screen = NSScreen.screens.first(where: { $0.frame.contains(origin) }) ?? window.screen ?? NSScreen.main {
            let link = screen.displayLink(target: WindowSpring.self, selector: #selector(WindowSpring.tick))
            mover = WindowSpring(window: window, link: link)
            WindowSpring.running[key] = mover
            link.add(to: .main, forMode: .common)
        } else {
            window.setFrameOrigin(origin)
            return
        }
        mover.target = origin
        mover.spring = spring.tuned  // once per move, not per frame
        if let velocity { mover.velocity = velocity }
    }

    /// Stops a window's spring where it is: a finger took over, or the window is going away.
    static func stop(_ window: NSWindow) { stop(ObjectIdentifier(window)) }

    private static func stop(_ key: ObjectIdentifier) {
        WindowSpring.running.removeValue(forKey: key)?.link.invalidate()
    }

    /// Scales a layer toward `scale` (and leaves it there) — the counterpart to `pop` on the way out.
    static func shrink(_ view: NSView, to scale: CGFloat = 0.94, duration: TimeInterval = 0.2) {
        guard !reduced, let layer = view.layer else { return }
        centerAnchor(layer)
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 1
        a.toValue = scale
        a.duration = duration * pace
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

/// One window's spring. Integrated in small fixed steps, so it moves the same at 60 and 120 Hz
/// and a dropped frame doesn't make it jump or blow up.
@MainActor
private final class WindowSpring: NSObject {
    static var running: [ObjectIdentifier: WindowSpring] = [:]
    weak var window: NSWindow?
    let link: CADisplayLink
    var target: CGPoint = .zero
    var velocity: CGVector = .zero
    /// Already tuned to the user's speed and bounce.
    var spring: Motion.Spring = .glide
    private var position: CGPoint
    private var last: CFTimeInterval?

    init(window: NSWindow, link: CADisplayLink) {
        self.window = window
        self.link = link
        position = window.frame.origin
    }

    /// The link calls the class, which finds the mover by its link: a link holds its target
    /// strongly, so targeting the mover would keep it alive after its window is gone.
    @objc static func tick(_ link: CADisplayLink) {
        guard let (key, mover) = running.first(where: { $0.value.link === link }) else { return link.invalidate() }
        if mover.step(link) {
            running.removeValue(forKey: key)
            link.invalidate()
        }
    }

    /// Advances to this frame; true once settled.
    private func step(_ link: CADisplayLink) -> Bool {
        guard let window else { return true }
        let now = link.targetTimestamp
        let dt = min(max(now - (last ?? link.timestamp), 0), 1.0 / 30)
        last = now
        // Mass 1: stiffness from the period, damping from the ratio (bounce 0 = critical).
        let omega = 2 * Double.pi / spring.response
        let k = omega * omega, c = 2 * omega * (1 - spring.bounce)
        var t = 0.0
        while t < dt {
            let h = min(1.0 / 480, dt - t)
            velocity.dx += (k * (target.x - position.x) - c * velocity.dx) * h
            velocity.dy += (k * (target.y - position.y) - c * velocity.dy) * h
            position.x += velocity.dx * h
            position.y += velocity.dy * h
            t += h
        }
        let settled = hypot(target.x - position.x, target.y - position.y) < 0.25 && hypot(velocity.dx, velocity.dy) < 4
        if settled { position = target; velocity = .zero }
        window.setFrameOrigin(position)
        return settled
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
