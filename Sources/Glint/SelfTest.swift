import AVFoundation
import AppKit
import GlintCore

/// `Glint --self-test`: runs every capture path for real — no mouse, no UI — and exits
/// non-zero on failure. Started from a terminal, it uses the terminal's Screen Recording
/// permission, so it works before Glint itself has been allowed.
@MainActor
enum SelfTest {
    private static var failures = 0

    static func run() async -> Never {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glint-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        check("Screen Recording permission", Capturer.hasPermission)

        // 1. Every display, at its own resolution — mixed Retina / non-Retina setups included.
        let shots = (try? await Capturer.captureDisplays()) ?? []
        check("captured \(shots.count) of \(NSScreen.screens.count) displays", shots.count == NSScreen.screens.count)
        for shot in shots {
            let expected = CGSize(width: shot.screen.frame.width * shot.scale, height: shot.screen.frame.height * shot.scale)
            check("  \(shot.screen.localizedName): \(shot.image.width)×\(shot.image.height) @\(Int(shot.scale))x",
                  CGFloat(shot.image.width) == expected.width && CGFloat(shot.image.height) == expected.height)
        }

        // 2. A single window, even if covered.
        if let screen = NSScreen.main, let window = Capturer.windows(on: screen).first {
            do {
                let (image, scale) = try await Capturer.captureWindow(window.id)
                dump(image, scale: scale, as: "window.png")
                check("window \(window.id): \(image.width)×\(image.height) @\(Int(scale))x, has alpha",
                      image.width >= Int(window.frame.width * scale) && image.alphaInfo != .none && image.alphaInfo != .noneSkipLast)
            } catch { check("window capture: \(error.localizedDescription)", false) }
        } else {
            print("  skip window capture (no windows on the main screen)")
        }

        // 3. Repeated region grabs (scrolling capture's engine), timed.
        if let screen = NSScreen.main {
            let rect = CGRect(x: 100, y: 100, width: 600, height: 400)
            do {
                let grab = try await Capturer.regionGrabber(screen: screen, rect: rect)
                let start = Date()
                var sizes: Set<String> = []
                for _ in 0..<5 { let img = try await grab(); sizes.insert("\(img.width)×\(img.height)") }
                let ms = Int(Date().timeIntervalSince(start) * 1000 / 5)
                check("region grab 5×: \(sizes.joined()), \(ms) ms each",
                      sizes == ["\(Int(rect.width * screen.backingScaleFactor))×\(Int(rect.height * screen.backingScaleFactor))"] && ms < 400)
            } catch { check("region grab: \(error.localizedDescription)", false) }

            // 4. Two seconds of video, then a GIF of it.
            do {
                let url = dir.appendingPathComponent("rec.mp4")
                let recorder = try await Recorder(screen: screen, rect: rect, to: url)
                try await recorder.start()
                try await Task.sleep(for: .seconds(2))
                _ = try await recorder.stop()
                let duration = try await AVURLAsset(url: url).load(.duration).seconds
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                check(String(format: "recording: %.1f s, %d KB", duration, size / 1024), duration > 0.5 && size > 1000)
                let gif = try await GIFExport.make(from: url)
                let frames = CGImageSourceCreateWithURL(gif as CFURL, nil).map(CGImageSourceGetCount) ?? 0
                check("GIF export: \(frames) frames", frames >= 6)
            } catch { check("recording: \(error.localizedDescription)", false) }
        }

        // 5. Scrolling capture end to end: a window of our own with 120 numbered lines,
        //    scrolled step by step, stitched, then read back with OCR.
        if let screen = NSScreen.main {
            await scrollingCapture(on: screen)
        }

        // 6. OCR on a real screen.
        if let shot = shots.first {
            let text = await TextRecognizer.text(in: shot.image)
            check("OCR on display 1: \(text.split(whereSeparator: \.isWhitespace).count) words", !text.isEmpty)
        }

        print(failures == 0 ? "\nSELF-TEST PASSED" : "\nSELF-TEST FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }

    private static func scrollingCapture(on screen: NSScreen) async {
        let size = CGSize(width: 520, height: 420)
        let origin = CGPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40)
        let window = NSWindow(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = CGRect(origin: .zero, size: size)
        scroll.hasVerticalScroller = false  // a scroller appearing mid-test would reflow the text
        let text = scroll.documentView as! NSTextView
        text.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        text.string = (1...120).map { "Line \($0) — the quick brown fox" }.joined(separator: "\n")
        window.contentView = scroll
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(400))

        // The window's content area in the screen's top-left-origin points.
        let rect = CGRect(x: origin.x - screen.frame.minX, y: screen.frame.maxY - origin.y - size.height, width: size.width, height: size.height)
        do {
            let grab = try await Capturer.regionGrabber(screen: screen, rect: rect, includeOwnWindows: true)
            let scale = screen.backingScaleFactor
            var stitcher = Stitcher(width: Int(size.width * scale), height: Int(size.height * scale))
            let documentHeight = text.frame.height
            var y: CGFloat = 0
            while true {
                stitcher.add(try await grab())
                if y >= documentHeight - size.height { break }
                y = min(y + 170, documentHeight - size.height)
                scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard let image = stitcher.image() else { return check("scrolling capture: no image", false) }
            dump(image, scale: scale, as: "scrolling.png")
            let expected = Int(documentHeight * scale)
            check("scrolling capture: \(image.height) px tall (document \(expected) px)", abs(image.height - expected) <= Int(8 * scale))
            // The exact height above proves nothing was skipped or doubled; OCR confirms the
            // content is really there. Vision misreads a few small 1× digits, hence 90 %.
            let read = await TextRecognizer.text(in: image)
            let numbers = Set(read.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { (1...120).contains($0) })
            check("  OCR reads \(numbers.count)/120 line numbers, incl. first and last",
                  numbers.count >= 108 && numbers.contains(1) && numbers.contains(120))
        } catch {
            check("scrolling capture: \(error.localizedDescription)", false)
        }
    }

    /// `GLINT_SELFTEST_DUMP=<dir>` keeps result images for a look.
    private static func dump(_ image: CGImage, scale: CGFloat, as name: String) {
        guard let dir = ProcessInfo.processInfo.environment["GLINT_SELFTEST_DUMP"] else { return }
        try? Capture.png(image, scale: scale).write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    private static func check(_ label: String, _ ok: Bool) {
        print("  \(ok ? "ok  " : "FAIL") \(label)")
        if !ok { failures += 1 }
    }
}
