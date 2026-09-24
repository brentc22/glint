import AppKit
import ScreenCaptureKit

/// A frozen image of one display, taken before the selection overlay appears — so what
/// you select is exactly what you saw, menus and hover states included.
struct DisplayShot {
    let screen: NSScreen
    let image: CGImage
    var scale: CGFloat { screen.backingScaleFactor }
}

/// A window you can pick in window mode. `frame` is in the screen's view coordinates
/// (points, top-left origin of that screen), ready for hit-testing in the overlay.
struct PickableWindow {
    let id: CGWindowID
    let frame: CGRect
}

enum CaptureError: LocalizedError {
    case permissionDenied, windowGone
    var errorDescription: String? {
        self == .permissionDenied ? "Glint needs Screen Recording permission." : "That window closed before it could be captured."
    }
}

enum Capturer {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Every display, captured at full Retina resolution without the cursor.
    static func captureDisplays() async throws -> [DisplayShot] {
        guard hasPermission else { throw CaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let own = content.windows.filter { $0.owningApplication?.processID == getpid() }
        var shots: [DisplayShot] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let config = SCStreamConfiguration()
            config.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
            config.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
            config.showsCursor = false
            config.captureResolution = .best
            let filter = SCContentFilter(display: display, excludingWindows: own)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            shots.append(DisplayShot(screen: screen, image: image))
        }
        return shots
    }

    /// One window on its own — even when other windows cover it — with its shadow and
    /// transparent corners, like macOS's own window capture.
    static func captureWindow(_ windowID: CGWindowID) async throws -> (CGImage, CGFloat) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureError.windowGone }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = false
        config.shouldBeOpaque = false
        return (try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config), scale)
    }

    /// Normal app windows on `screen`, front to back. CGWindowList gives the z-order;
    /// SCShareableContent's order isn't guaranteed.
    static func windows(on screen: NSScreen) -> [PickableWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let screenTop = screen.cgFrame
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != getpid(),
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.width > 40, bounds.height > 40, bounds.intersects(screenTop) else { return nil }
            return PickableWindow(id: id, frame: bounds.offsetBy(dx: -screenTop.minX, dy: -screenTop.minY))
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// This screen's frame in CoreGraphics global coordinates (top-left of the main display).
    var cgFrame: CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? frame.height
        return CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
