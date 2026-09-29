import AVFoundation
import AppKit
import GlintCore

/// Screen recording of a region: red frame, a running timer, Pause and Stop. Produces an
/// MP4 in the save folder and a `Capture` carrying its first frame as the thumbnail.
@MainActor
final class RecordingSession: NSObject {
    private let screen: NSScreen
    private let rect: CGRect
    private let completion: (Capture?) -> Void
    private var chrome: SessionChrome!
    private var pauseButton: NSButton!
    private var recorder: Recorder?
    private var overlays: [RecordingOverlay] = []
    private var timer: Timer?
    /// Recorded time before the current stretch, and when the current stretch began.
    private var recorded: TimeInterval = 0
    private var runningSince: Date?
    private var stopping = false

    init(screen: NSScreen, rect: CGRect, completion: @escaping (Capture?) -> Void) {
        self.screen = screen
        self.rect = rect
        self.completion = completion
        super.init()
        let stop = NSButton(title: "Stop", target: self, action: #selector(stop))
        stop.keyEquivalent = "\r"
        pauseButton = NSButton(title: "Pause", target: self, action: #selector(togglePause))
        pauseButton.isEnabled = false
        chrome = SessionChrome(screen: screen, rect: rect, color: .systemRed, symbol: "record.circle.fill",
                               buttons: [NSButton(title: "Cancel", target: self, action: #selector(cancel)), pauseButton, stop])
        chrome.status.stringValue = "Recording  0:00"
    }

    func start() {
        chrome.show()
        Task {
            do {
                if Prefs.recordCountdown {
                    for n in [3, 2, 1] {
                        chrome.status.stringValue = "Starting in \(n)…"
                        try await Task.sleep(for: .seconds(1))
                        if stopping { return }
                    }
                }
                var options = Recorder.Options(fps: Prefs.recordFPS, systemAudio: Prefs.recordSystemAudio,
                                               microphone: Prefs.recordMicrophone, showsCursor: true)
                if options.microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                    options.microphone = false
                    Toast.show("Recording without the microphone: allow it in Privacy & Security", symbol: "mic.slash.fill")
                }
                await makeOverlays()
                options.keep = Set(overlays.map(\.windowID))
                try FileManager.default.createDirectory(at: Prefs.saveFolder, withIntermediateDirectories: true)
                let url = FileNaming.unique(FileNaming.name(prefix: Prefs.filenamePrefix, ext: "mp4"), in: Prefs.saveFolder)
                let recorder = try await Recorder(screen: screen, rect: rect, to: url, options: options)
                try await recorder.start()
                guard !stopping else {
                    _ = try? await recorder.stop()
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                self.recorder = recorder
                runningSince = Date()
                pauseButton.isEnabled = true
                tick()
                // Strong capture is fine: the timer is invalidated when the session ends.
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    MainActor.assumeIsolated { self.tick() }
                }
            } catch {
                fail(error)
            }
        }
    }

    /// Click rings, keystrokes and webcam, as chosen in Settings → Recording. Shown before
    /// the recorder starts, so their windows exist when it decides what to leave out.
    private func makeOverlays() async {
        let area = screen.globalRect(fromTopLeft: rect)
        if Prefs.recordClicks { overlays.append(ClickRings(area: area)) }
        if Prefs.recordKeystrokes {
            if !KeystrokeHUD.requestPermission() {
                Toast.show("Allow Glint under Accessibility to show shortcuts from other apps", symbol: "keyboard")
            }
            overlays.append(KeystrokeHUD(area: area))
        }
        if Prefs.recordWebcam {
            if await WebcamBubble.requestPermission(), let bubble = WebcamBubble(area: area) {
                overlays.append(bubble)
            } else {
                Toast.show("No camera, or Glint isn't allowed to use it", symbol: "video.slash.fill")
            }
        }
        overlays.forEach { $0.show() }
    }

    private var elapsed: TimeInterval { recorded + (runningSince.map { Date().timeIntervalSince($0) } ?? 0) }

    private func tick() {
        let s = Int(elapsed)
        let time = "\(s / 60):\(String(format: "%02d", s % 60))"
        chrome.status.stringValue = runningSince == nil ? "Paused  \(time)" : "Recording  \(time)"
    }

    @objc private func togglePause() {
        guard let recorder else { return }
        if let since = runningSince {
            recorded += Date().timeIntervalSince(since)
            runningSince = nil
            recorder.pause()
            pauseButton.title = "Resume"
        } else {
            runningSince = Date()
            recorder.resume()
            pauseButton.title = "Pause"
        }
        tick()
    }

    @objc func stop() { end(keep: true) }
    @objc private func cancel() { end(keep: false) }

    private func end(keep: Bool) {
        guard !stopping else { return }
        stopping = true
        timer?.invalidate()
        chrome.status.stringValue = "Saving…"
        overlays.forEach { $0.close() }
        Task {
            guard let recorder else { return finishUp(nil) }
            do {
                let url = try await recorder.stop()
                guard keep else {
                    try? FileManager.default.removeItem(at: url)
                    return finishUp(nil)
                }
                let thumb = try await AVAssetImageGenerator(asset: AVURLAsset(url: url)).image(at: .zero).image
                finishUp(Capture(image: thumb, scale: screen.backingScaleFactor, file: url))
            } catch {
                fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        finishUp(nil)
    }

    private func finishUp(_ capture: Capture?) {
        timer?.invalidate()
        overlays.forEach { $0.close() }
        overlays.removeAll()
        chrome.close()
        completion(capture)
    }
}

/// MP4 → looping GIF next to it: 12 fps, at most 960 px wide — small enough for
/// GitHub issues and Slack, smooth enough for a UI demo.
enum GIFExport {
    static func make(from video: URL) async throws -> URL {
        let asset = AVURLAsset(url: video)
        // The video track, not the asset: with sound, the audio can run a few ms longer,
        // and a frame asked for past the last picture fails.
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CaptureError.nothingRecorded }
        let duration = try await track.load(.timeRange).duration.seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 960, height: 960)
        let fps = 12.0
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = .zero
        var frames: [CGImage] = []
        for i in 0..<max(1, Int(duration * fps)) {
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            // One unreadable frame holds the previous one instead of losing the whole GIF.
            if let image = try? await generator.image(at: time).image {
                frames.append(image)
            } else if let last = frames.last {
                frames.append(last)
            }
        }
        guard let data = GIFEncoder.encode(frames, delay: 1 / fps) else { throw CaptureError.nothingRecorded }
        let url = video.deletingPathExtension().appendingPathExtension("gif")
        try data.write(to: url)
        return url
    }
}
