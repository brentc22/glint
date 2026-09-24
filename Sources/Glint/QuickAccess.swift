import AppKit
import SwiftUI

/// What the quick-access card can ask the app to do.
struct CaptureActions {
    let edit: (Capture) -> Void
    let pin: (Capture) -> Void
    let redact: (Capture) -> Void
    let copyText: (Capture) -> Void
    let makeGIF: (Capture) -> Void
}

/// The floating thumbnails in the corner after a capture. Hover for actions, drag the
/// thumbnail into any app, click to annotate. Newest at the bottom; they leave on their own.
@MainActor
final class QuickAccess {
    private var cards: [(capture: Capture, panel: NSPanel)] = []
    private let actions: CaptureActions
    private static let width: CGFloat = 260, gap: CGFloat = 12, maxCards = 4

    init(actions: CaptureActions) { self.actions = actions }

    func show(_ capture: Capture, on screen: NSScreen?) {
        if cards.count >= Self.maxCards { close(cards[0].capture) }
        let aspect = capture.pointSize.height / max(capture.pointSize.width, 1)
        let height = min(max(Self.width * aspect, 80), 200)
        let view = QuickAccessCard(capture: capture, actions: actions, close: { [weak self] in self?.close(capture) })
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: view)
        cards.append((capture, panel))
        layout(on: screen ?? NSScreen.main)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
    }

    func close(_ capture: Capture) {
        guard let i = cards.firstIndex(where: { $0.capture === capture }) else { return }
        let panel = cards.remove(at: i).panel
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; panel.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
        layout(on: panel.screen)
    }

    /// Stacks cards upward from the chosen bottom corner, newest lowest.
    private func layout(on screen: NSScreen?) {
        let area = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = Prefs.quickAccessCorner == .left ? area.minX + 20 : area.maxX - 20 - Self.width
        var y = area.minY + 20
        for card in cards.reversed() {
            let h = card.panel.frame.height
            card.panel.setFrame(CGRect(x: x, y: y, width: Self.width, height: h), display: true, animate: true)
            y += h + Self.gap
        }
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
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white, .black.opacity(0.4))
            }

            if state.hovering, capture.isVideo, let file = capture.file {
                Color.black.opacity(0.45)
                VStack(spacing: 8) {
                    pill("Copy", "doc.on.doc") { capture.copy(); flash() }
                    pill("Save as GIF", "photo.stack") { actions.makeGIF(capture) }
                }
                VStack {
                    HStack {
                        corner("xmark", help: "Close") { close() }
                        Spacer()
                        corner("play.fill", help: "Play") { NSWorkspace.shared.open(file) }
                    }
                    Spacer()
                    HStack {
                        corner("folder", help: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        Spacer()
                    }
                }
                .padding(8)
            } else if state.hovering {
                Color.black.opacity(0.45)
                VStack(spacing: 8) {
                    pill("Copy", "doc.on.doc") { capture.copy(); flash() }
                    pill("Save As…", "square.and.arrow.down") { capture.saveAs() }
                }
                VStack {
                    HStack {
                        corner("xmark", help: "Close") { close() }
                        Spacer()
                        corner("pencil.tip.crop.circle", help: "Annotate") { actions.edit(capture); close() }
                    }
                    Spacer()
                    HStack {
                        corner("pin", help: "Pin to screen") { actions.pin(capture); close() }
                        corner("text.viewfinder", help: "Copy text (OCR)") { actions.copyText(capture) }
                        Spacer()
                        corner("eye.slash", help: "Redact emails, IBANs, keys…") { actions.redact(capture) }
                    }
                }
                .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { state.hovering = inside }
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

    private func pill(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 110, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.white.opacity(0.22), in: Capsule())
    }

    private func corner(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.black.opacity(0.45), in: Circle())
        .help(help)
    }
}
