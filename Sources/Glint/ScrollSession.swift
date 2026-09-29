import AppKit
import GlintCore

/// Scrolling capture: grabs the selected region ~8× a second while you scroll, stitching
/// as it goes.
@MainActor
final class ScrollSession: NSObject {
    private let screen: NSScreen
    private let rect: CGRect  // points, top-left origin of `screen`
    private let completion: (Capture?) -> Void
    private var stitcher: Stitcher
    private var running = true
    private var chrome: SessionChrome!
    private var autoButton: NSButton!
    private var autoScrolling = false
    /// Stops at 40 000 px — past that the image is too big for most apps to open anyway.
    private static let maxHeight = 40_000

    init(screen: NSScreen, rect: CGRect, completion: @escaping (Capture?) -> Void) {
        self.screen = screen
        self.rect = rect
        self.completion = completion
        stitcher = Stitcher(width: Int(rect.width * screen.backingScaleFactor), height: Int(rect.height * screen.backingScaleFactor))
        super.init()
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        autoButton = NSButton(title: "Auto", target: self, action: #selector(toggleAuto))
        autoButton.toolTip = "Let Glint scroll to the end for you"
        chrome = SessionChrome(screen: screen, rect: rect, color: .controlAccentColor, symbol: "arrow.down.to.line.compact",
                               buttons: [NSButton(title: "Cancel", target: self, action: #selector(cancel)), autoButton, done])
        chrome.status.stringValue = "Scroll down slowly, or press Auto"
    }

    func start() {
        chrome.show()  // before the grabber: it excludes Glint's windows that exist at setup
        let center = screen.globalRect(fromTopLeft: rect)
        let target = CGPoint(x: center.midX, y: center.midY)
        Task {
            do {
                let grab = try await Capturer.regionGrabber(screen: screen, rect: rect)
                var still = 0
                while running {
                    if autoScrolling {
                        AutoScroll.step(at: target, points: rect.height * AutoScroll.stepShare)
                        try await Task.sleep(for: .milliseconds(160))  // let the page settle before grabbing
                    }
                    let image = try await grab()
                    guard running else { break }
                    let outcome = stitcher.add(image)
                    chrome.status.stringValue = outcome == .lost
                        ? "Too fast — scroll back a little"
                        : "\(autoScrolling ? "Scrolling" : "Scroll down slowly")…  \(stitcher.totalHeight.formatted()) px"
                    // At the end of the page the frames stop changing: done.
                    still = outcome == .unchanged ? still + 1 : 0
                    if autoScrolling, still >= AutoScroll.endAfter { finish(keep: true); break }
                    if stitcher.totalHeight >= Self.maxHeight { finish(keep: true); break }
                    if !autoScrolling { try await Task.sleep(for: .milliseconds(90)) }
                }
            } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
                finish(keep: false)
            }
        }
    }

    @objc private func toggleAuto() {
        if !autoScrolling, !AutoScroll.isAllowed(prompt: true) {
            Toast.show("Allow Glint under Accessibility to scroll for you", symbol: "hand.raised.fill")
            return
        }
        autoScrolling.toggle()
        autoButton.title = autoScrolling ? "Stop" : "Auto"
    }

    @objc func done() { finish(keep: true) }
    @objc private func cancel() { finish(keep: false) }

    private func finish(keep: Bool) {
        guard running else { return }
        running = false
        chrome.close()
        completion(keep ? stitcher.image().map { Capture(image: $0, scale: screen.backingScaleFactor) } : nil)
    }
}

/// Scrolls for you: wheel events posted at the middle of the region, a third of its height
/// at a time — small enough for the stitcher to always find the overlap. Posting events
/// needs the Accessibility permission.
@MainActor
enum AutoScroll {
    static let stepShare: CGFloat = 0.3
    /// Unchanged frames in a row that mean the page has ended.
    static let endAfter = 3

    static func isAllowed(prompt: Bool) -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString  // kAXTrustedCheckOptionPrompt, as a literal: it's a global var
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// `point` in AppKit global coordinates; the event wants CoreGraphics' top-left ones.
    static func step(at point: CGPoint, points: CGFloat) {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: -Int32(points.rounded()), wheel2: 0, wheel3: 0) else { return }
        event.location = CGPoint(x: point.x, y: mainHeight - point.y)
        event.post(tap: .cghidEventTap)
    }
}
