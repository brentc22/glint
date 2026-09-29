import AppKit
import SwiftUI

/// What the quick-access card can ask the app to do.
struct CaptureActions {
    let edit: (Capture) -> Void
    let pin: (Capture) -> Void
    let redact: (Capture) -> Void
    let copyText: (Capture) -> Void
    let makeGIF: (Capture) -> Void
    let trim: (Capture) -> Void
}

/// The floating thumbnails in the corner after a capture. Hover for actions, drag the
/// thumbnail into any app, click to annotate, swipe toward the edge to dismiss. Newest at
/// the bottom; they leave on their own.
@MainActor
final class QuickAccess {
    private var cards: [(capture: Capture, panel: CardPanel)] = []
    private let actions: CaptureActions
    private static let width: CGFloat = 260, gap: CGFloat = 12, maxCards = 4, margin: CGFloat = 20

    init(actions: CaptureActions) { self.actions = actions }

    /// `from`: where the capture was on screen (AppKit global coordinates). The shot flies
    /// from there into its card, so you see where it went.
    func show(_ capture: Capture, on screen: NSScreen?, from source: CGRect? = nil) {
        if cards.count >= Self.maxCards { close(cards[0].capture) }
        let aspect = capture.pointSize.height / max(capture.pointSize.width, 1)
        let height = min(max(Self.width * aspect, 80), 200)
        let view = QuickAccessCard(capture: capture, actions: actions, close: { [weak self] in self?.close(capture) })
        let panel = CardPanel(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: height),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: view)
        panel.edgeSign = Prefs.quickAccessCorner == .left ? -1 : 1
        panel.onSwipeAway = { [weak self] in self?.close(capture) }
        cards.append((capture, panel))

        let screen = screen ?? NSScreen.main
        let frames = slots(on: screen)
        let target = frames.last ?? .zero
        // The others make room first, the new card lands in the gap.
        for (card, frame) in zip(cards.dropLast(), frames) { card.panel.slide(to: frame) }
        panel.home = target

        if let source, !Motion.reduced, source.width > 8, source.height > 8,
           let flightScreen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: source.midX, y: source.midY)) }),
           flightScreen.frame.contains(CGPoint(x: target.midX, y: target.midY)) {
            panel.setFrame(target, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            ShotFlight.fly(capture.image, from: source, to: target, on: flightScreen) {
                panel.alphaValue = 1
            }
        } else {
            // In from the screen edge, like the macOS screenshot thumbnail, landing with a little give.
            let offset: CGFloat = Motion.reduced ? 0 : (Self.width + Self.margin) * panel.edgeSign
            panel.setFrame(target.offsetBy(dx: offset, dy: 0), display: false)
            panel.alphaValue = Motion.reduced ? 0 : 1
            panel.orderFrontRegardless()
            Motion.move(panel, to: target.origin, spring: .arrive)
            if Motion.reduced { Motion.animate(0.2) { panel.animator().alphaValue = 1 } }
        }
    }

    func close(_ capture: Capture) {
        guard let i = cards.firstIndex(where: { $0.capture === capture }) else { return }
        let panel = cards.remove(at: i).panel
        let screen = panel.screen
        // Out over the edge it came from — with the flick's speed if it was swiped; the rest close the gap.
        panel.ignoresMouseEvents = true
        if !Motion.reduced {
            let away = panel.frame.offsetBy(dx: (Self.width + Self.margin) * panel.edgeSign, dy: 0).origin
            Motion.move(panel, to: away, spring: .leave, velocity: panel.releaseVelocity)
        }
        panel.releaseVelocity = nil
        Motion.animate(0.22, Motion.exit, { panel.animator().alphaValue = 0 }, completion: {
            Motion.stop(panel)
            panel.orderOut(nil)
        })
        for (card, frame) in zip(cards, slots(on: screen)) { card.panel.slide(to: frame) }
    }

    /// Frames stacked upward from the chosen bottom corner, oldest first, newest lowest.
    private func slots(on screen: NSScreen?) -> [CGRect] {
        let area = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = Prefs.quickAccessCorner == .left ? area.minX + Self.margin : area.maxX - Self.margin - Self.width
        var y = area.minY + Self.margin
        var frames: [CGRect] = []
        for card in cards.reversed() {
            let h = card.panel.frame.height
            frames.insert(CGRect(x: x, y: y, width: Self.width, height: h), at: 0)
            y += h + Self.gap
        }
        return frames
    }
}

/// A card's window: follows a two-finger swipe sideways and dismisses when it's flicked
/// toward the screen edge, the way notifications and the macOS thumbnail do.
@MainActor
private final class CardPanel: NSPanel {
    var home: CGRect = .zero
    var edgeSign: CGFloat = 1
    var onSwipeAway: (() -> Void)?
    /// Sideways speed when the fingers lifted, so a dismissal or snap-back carries on from it.
    var releaseVelocity: CGVector?
    private var swipe: CGFloat = 0
    private var swiping = false
    private var speed: CGFloat = 0
    private var lastSwipe: TimeInterval = 0
    private var swipeY: CGFloat = 0

    func slide(to frame: CGRect) {
        home = frame
        guard !swiping else { return }
        Motion.move(self, to: frame.origin)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { return super.scrollWheel(with: event) }
        if !event.momentumPhase.isEmpty { return }  // the flick is judged when the fingers lift
        switch event.phase {
        case .began:
            // The finger takes over mid-flight, from wherever the card is.
            Motion.stop(self)
            swiping = true
            // Back to finger distance: the far side shows a quarter of it.
            let offset = frame.minX - home.minX
            swipe = offset * edgeSign > 0 ? offset : offset * 4
            swipeY = frame.minY
            speed = 0
            lastSwipe = event.timestamp
        case .changed:
            swipe += event.scrollingDeltaX
            // Smoothed, so one uneven event doesn't decide the flick.
            let dt = max(event.timestamp - lastSwipe, 1.0 / 240)
            lastSwipe = event.timestamp
            // Free toward the edge, rubber-banded the other way.
            let toward = swipe * edgeSign
            let shown = toward > 0 ? toward : toward / 4
            // The card's speed, not the finger's: on the rubber-banded side it's a quarter.
            let moved = toward > 0 ? event.scrollingDeltaX : event.scrollingDeltaX / 4
            speed = speed * 0.6 + (moved / dt) * 0.4
            setFrameOrigin(CGPoint(x: home.minX + shown * edgeSign, y: swipeY))
            alphaValue = 1 - min(0.6, max(0, toward) / 400)
        case .ended, .cancelled:
            swiping = false
            // A pause before lifting is no flick.
            if event.timestamp - lastSwipe > 0.08 { speed = 0 }
            releaseVelocity = CGVector(dx: speed, dy: 0)
            // Far enough, or fast enough toward the edge.
            if event.phase == .ended, swipe * edgeSign > 60 || speed * edgeSign > 600 {
                onSwipeAway?()
            } else {
                Motion.move(self, to: home.origin, spring: .arrive, velocity: releaseVelocity)
                releaseVelocity = nil
                Motion.animate(0.25) { self.animator().alphaValue = 1 }
            }
        default:
            break
        }
    }
}

/// The capture shrinking from where it was taken into its thumbnail. The window stays put and
/// covers the flight path; only a layer moves inside it, on a spring, entirely on the GPU. Resizing
/// a window every frame instead makes the window server redo it each time, and it stutters.
@MainActor
enum ShotFlight {
    static func fly(_ image: CGImage, from source: CGRect, to target: CGRect, on screen: NSScreen,
                    landed: @escaping () -> Void) {
        // Room around the path for the shadow and the landing's give; on one screen, never more.
        let area = source.union(target).insetBy(dx: -40, dy: -40).intersection(screen.frame)
        let panel = NSPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let root = NSView(frame: CGRect(origin: .zero, size: area.size))
        root.wantsLayer = true
        panel.contentView = root

        // Local to the panel; the shadow sits on an outer layer because the image clips its corners.
        let from = source.offsetBy(dx: -area.minX, dy: -area.minY)
        let to = target.offsetBy(dx: -area.minX, dy: -area.minY)
        let shadow = CALayer()
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = 0.35
        shadow.shadowRadius = 14
        shadow.shadowOffset = CGSize(width: 0, height: -6)
        let shot = CALayer()
        shot.contents = image
        shot.contentsGravity = .resizeAspectFill
        shot.masksToBounds = true
        shot.cornerCurve = .continuous
        shot.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        shot.borderWidth = 0.5
        shadow.addSublayer(shot)
        root.layer?.addSublayer(shadow)

        let spring = Motion.Spring.arrive
        let radius: CGFloat = 12
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // When the springs are done, not when a clock guesses they are.
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                landed()
                // One frame for the card to draw, then the stand-in goes.
                DispatchQueue.main.async { panel.orderOut(nil) }
            }
        }
        // Final state as the model; the springs run from where it was taken.
        shadow.frame = to
        shot.frame = shadow.bounds
        shot.cornerRadius = radius
        shadow.shadowPath = CGPath(roundedRect: shadow.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let fromBounds = CGRect(origin: .zero, size: from.size)
        let moves: [(CALayer, String, Any, Any)] = [
            (shadow, "position", CGPoint(x: from.midX, y: from.midY), CGPoint(x: to.midX, y: to.midY)),
            (shadow, "bounds", fromBounds, shadow.bounds),
            (shadow, "shadowPath", CGPath(roundedRect: fromBounds, cornerWidth: 0.1, cornerHeight: 0.1, transform: nil), shadow.shadowPath!),
            (shadow, "shadowOpacity", 0, 0.35),
            (shot, "position", CGPoint(x: fromBounds.midX, y: fromBounds.midY), CGPoint(x: shot.bounds.midX, y: shot.bounds.midY)),
            (shot, "bounds", fromBounds, shot.bounds),
            (shot, "cornerRadius", 0, radius),
        ]
        for (layer, keyPath, a, b) in moves {
            layer.add(Motion.springAnimation(keyPath, from: a, to: b, spring), forKey: keyPath)
        }
        panel.orderFrontRegardless()
        CATransaction.commit()
    }
}

/// Card state as an `ObservableObject`: `@State` is a macro in the macOS 27 SDK whose
/// plugin only ships with Xcode, so it doesn't build with the Command Line Tools.
@MainActor
private final class CardState: ObservableObject {
    @Published var hovering = false
    var dismissTask: Task<Void, Never>?
}

private struct QuickAccessCard: View {
    @ObservedObject var capture: Capture
    let actions: CaptureActions
    let close: () -> Void
    @StateObject private var state = CardState()

    var body: some View {
        ZStack {
            Image(nsImage: capture.nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            if capture.isVideo, !state.hovering {
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
                    .environment(\.colorScheme, .dark)
                    .transition(.opacity)
            }

            if state.hovering {
                LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.2), .black.opacity(0.45)],
                               startPoint: .top, endPoint: .bottom)
                    .transition(.opacity)
                Group {
                    if capture.isVideo, let file = capture.file {
                        controls(
                            pills: [("Copy", "doc.on.doc", { capture.copy(); flash() }),
                                    ("Save as GIF", "photo.stack", { actions.makeGIF(capture) })],
                            topLeft: ("xmark", "Close", close),
                            topRight: ("play.fill", "Play", { NSWorkspace.shared.open(file) }),
                            bottom: [("folder", "Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([file]) }),
                                     ("scissors", "Trim", { actions.trim(capture) })],
                            bottomRight: nil)
                    } else {
                        controls(
                            pills: [("Copy", "doc.on.doc", { capture.copy(); flash() }),
                                    ("Save As…", "square.and.arrow.down", { capture.saveAs() })],
                            topLeft: ("xmark", "Close", close),
                            topRight: ("pencil.tip.crop.circle", "Annotate", { actions.edit(capture); close() }),
                            bottom: [("pin", "Pin to screen", { actions.pin(capture); close() }),
                                     ("text.viewfinder", "Copy text (OCR)", { actions.copyText(capture) })],
                            bottomRight: ("eye.slash", "Redact emails, IBANs, keys…", { actions.redact(capture) }))
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .onHover { inside in
            withAnimation(Motion.spring) { state.hovering = inside }
            inside ? state.dismissTask?.cancel() : scheduleDismiss()
        }
        .onTapGesture(count: 2) {
            if capture.isVideo, let file = capture.file { NSWorkspace.shared.open(file) } else { actions.edit(capture); close() }
        }
        .onDrag {
            if let file = capture.file, let provider = NSItemProvider(contentsOf: file) { return provider }
            return NSItemProvider(object: capture.nsImage)
        }
        .onAppear { scheduleDismiss() }
    }

    private func scheduleDismiss() {
        state.dismissTask?.cancel()
        let seconds = Prefs.quickAccessSeconds
        guard seconds > 0 else { return }
        state.dismissTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { close() }
        }
    }

    private func flash() { Toast.show("Copied to clipboard") }

    private typealias Action = (symbol: String, help: String, run: () -> Void)

    private func controls(pills: [(String, String, () -> Void)], topLeft: Action, topRight: Action,
                          bottom: [Action], bottomRight: Action?) -> some View {
        ZStack {
            VStack(spacing: 8) {
                ForEach(pills.indices, id: \.self) { i in pill(pills[i].0, pills[i].1, action: pills[i].2) }
            }
            VStack {
                HStack {
                    corner(topLeft)
                    Spacer()
                    corner(topRight)
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(bottom.indices, id: \.self) { i in corner(bottom[i]) }
                    Spacer()
                    if let bottomRight { corner(bottomRight) }
                }
            }
            .padding(8)
        }
        .environment(\.colorScheme, .dark)
    }

    private func pill(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 118, height: 28)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.white)
    }

    private func corner(_ a: Action) -> some View {
        Button(action: a.run) {
            Image(systemName: a.symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.white)
        .help(a.help)
    }
}
