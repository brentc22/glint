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
        chrome = SessionChrome(screen: screen, rect: rect, color: .controlAccentColor, symbol: "arrow.down.to.line.compact",
                               buttons: [NSButton(title: "Cancel", target: self, action: #selector(cancel)), done])
        chrome.status.stringValue = "Scroll down slowly…"
    }

    func start() {
        chrome.show()  // before the grabber: it excludes Glint's windows that exist at setup
        Task {
            do {
                let grab = try await Capturer.regionGrabber(screen: screen, rect: rect)
                while running {
                    let image = try await grab()
                    guard running else { break }
                    chrome.status.stringValue = stitcher.add(image) == .lost
                        ? "Too fast — scroll back a little"
                        : "Scroll down slowly…  \(stitcher.totalHeight.formatted()) px"
                    if stitcher.totalHeight >= Self.maxHeight { finish(keep: true); break }
                    try await Task.sleep(for: .milliseconds(90))
                }
            } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
                finish(keep: false)
            }
        }
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
