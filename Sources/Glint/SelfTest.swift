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
        setvbuf(stdout, nil, _IOLBF, 0)  // piped to a file or CI, show each step as it happens
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glint-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        check("Screen Recording permission", await Capturer.hasPermission())

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
                dump(Renderer.windowShadow(image, scale: scale), scale: scale, as: "window.png")
                check("window \(window.id): \(image.width)×\(image.height) @\(Int(scale))x, has alpha",
                      image.width == Int(window.frame.width * scale) && image.height == Int(window.frame.height * scale)
                      && image.alphaInfo != .none && image.alphaInfo != .noneSkipLast)
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
                // With system audio, and a one-second pause in the middle that mustn't show up.
                let recorder = try await Recorder(screen: screen, rect: rect, to: url,
                                                  options: .init(fps: 60, systemAudio: true))
                try await recorder.start()
                try await Task.sleep(for: .seconds(1))
                recorder.pause()
                try await Task.sleep(for: .seconds(1))
                recorder.resume()
                try await Task.sleep(for: .seconds(1))
                _ = try await recorder.stop()
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                let audio = try await asset.loadTracks(withMediaType: .audio).count
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                check(String(format: "recording: %.1f s (1 s paused), %d audio track, %d KB", duration, audio, size / 1024),
                      duration > 1.6 && duration < 2.5 && audio == 1 && size > 1000)
                await mixdown(dir)
                await overlaysInVideo(screen: screen, rect: rect, dir: dir)
                let trimmed = dir.appendingPathComponent("trim.mp4")
                try FileManager.default.copyItem(at: url, to: trimmed)
                try await TrimWindow.trim(trimmed, to: CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                                  duration: CMTime(seconds: 1, preferredTimescale: 600)))
                let kept = try await AVURLAsset(url: trimmed).load(.duration).seconds
                check(String(format: "trim to 1 s: %.2f s", kept), abs(kept - 1) < 0.15)
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

    /// Click rings and shortcuts are Glint windows, which recordings normally leave out;
    /// these must end up in the video. Compares a frame before and after they appear.
    private static func overlaysInVideo(screen: NSScreen, rect: CGRect, dir: URL) async {
        let url = dir.appendingPathComponent("overlays.mp4")
        let area = screen.globalRect(fromTopLeft: rect)
        let rings = ClickRings(area: area), keys = KeystrokeHUD(area: area)
        rings.show(); keys.show()
        defer { rings.close(); keys.close() }
        do {
            let recorder = try await Recorder(screen: screen, rect: rect, to: url,
                                              options: .init(showsCursor: false, keep: [rings.windowID, keys.windowID]))
            try await recorder.start()
            try await Task.sleep(for: .milliseconds(600))
            keys.display("⌘⇧K")
            rings.ring(at: CGPoint(x: area.midX, y: area.midY))
            try await Task.sleep(for: .milliseconds(300))
            _ = try await recorder.stop()
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let before = try await generator.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)).image
            let after = try await generator.image(at: CMTime(seconds: 0.8, preferredTimescale: 600)).image
            if let path = ProcessInfo.processInfo.environment["GLINT_SELFTEST_FRAME"] {  // for eyeballing
                try Capture.png(after, scale: 1).write(to: URL(fileURLWithPath: path))
            }
            let changed = differingPixels(before, after)
            check("click ring and shortcut are in the video: \(changed) px changed", changed > 2000)
        } catch { check("overlays in video: \(error.localizedDescription)", false) }
    }

    private static func differingPixels(_ a: CGImage, _ b: CGImage) -> Int {
        guard a.width == b.width, a.height == b.height else { return -1 }
        func bytes(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
        let (x, y) = (bytes(a), bytes(b))
        return stride(from: 0, to: x.count, by: 4).filter { i in (0..<3).contains { abs(Int(x[i + $0]) - Int(y[i + $0])) > 40 } }.count
    }

    /// A file with two tones on two audio tracks, as a recording with system audio and the
    /// microphone has, mixed down to one track that still lasts as long.
    private static func mixdown(_ dir: URL) async {
        let url = dir.appendingPathComponent("two-tracks.mp4")
        do {
            try await SyntheticVideo.write(to: url, seconds: 2, tones: [440, 660])
            let before = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).count
            try await AudioMixdown.run(url)
            let asset = AVURLAsset(url: url)
            let after = try await asset.loadTracks(withMediaType: .audio).count
            let video = try await asset.loadTracks(withMediaType: .video).count
            let duration = try await asset.load(.duration).seconds
            check(String(format: "audio mixdown: %d → %d tracks, video kept, %.1f s", before, after, duration),
                  before == 2 && after == 1 && video == 1 && abs(duration - 2) < 0.2)
        } catch { check("audio mixdown: \(error.localizedDescription)", false) }
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

/// A small MP4 made from nothing: grey frames plus one sine tone per audio track.
private enum SyntheticVideo {
    /// Waits a moment for an input to take more; a failed writer never will, so that throws.
    private static func ready(_ writer: AVAssetWriter) async throws {
        if writer.status == .failed { throw writer.error ?? CaptureError.nothingRecorded }
        try await Task.sleep(for: .milliseconds(2))
    }

    static func write(to url: URL, seconds: Int, tones: [Double]) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        writer.add(video)
        let audio = tones.map { _ in
            AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
        }
        audio.forEach(writer.add)
        // Otherwise the writer holds one input back until the others pass its interleave
        // window, and a loop that feeds them in turn waits forever.
        ([video] + audio).forEach { $0.expectsMediaDataInRealTime = true }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let rate = 48_000.0, chunk = 4800  // 100 ms
        var format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                 mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                 mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        // Interleaved in 100 ms slices: the writer waits for every track to catch up, so
        // writing all video first and then the audio deadlocks.
        for slice in 0..<(seconds * 10) {
            for frame in (slice * 3)..<(slice * 3 + 3) {
                while !video.isReadyForMoreMediaData { try await ready(writer) }
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, nil, &buffer)
                guard let buffer else { continue }
                CVPixelBufferLockBaseAddress(buffer, [])
                memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 4 % 255), CVPixelBufferGetDataSize(buffer))
                CVPixelBufferUnlockBaseAddress(buffer, [])
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
            }
            let start = slice * chunk
            for (input, tone) in zip(audio, tones) {
                while !input.isReadyForMoreMediaData { try await ready(writer) }
                var samples = [Int16](repeating: 0, count: chunk * 2)
                for i in 0..<chunk {
                    let v = Int16(sin(2 * .pi * tone * Double(start + i) / rate) * 8000)
                    samples[i * 2] = v; samples[i * 2 + 1] = v
                }
                var block: CMBlockBuffer?
                let bytes = samples.count * 2
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                   customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
                guard let block else { continue }
                _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
                var sample: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: description!,
                                                                     sampleCount: chunk, presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: 48_000),
                                                                     packetDescriptions: nil, sampleBufferOut: &sample)
                if let sample { input.append(sample) }
            }
        }
        video.markAsFinished()
        audio.forEach { $0.markAsFinished() }
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}
