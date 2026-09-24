import AVFoundation
import AppKit
import GlintCore

/// Screen recording of a region: red frame, a running timer, Stop. Produces an MP4 in
/// the save folder and a `Capture` carrying its first frame as the thumbnail.
@MainActor
final class RecordingSession: NSObject {
    private let screen: NSScreen
    private let rect: CGRect
    private let completion: (Capture?) -> Void
    private var chrome: SessionChrome!
    private var recorder: Recorder?
    private var timer: Timer?
    private let startedAt = Date()
    private var stopping = false

    init(screen: NSScreen, rect: CGRect, completion: @escaping (Capture?) -> Void) {
        self.screen = screen
        self.rect = rect
        self.completion = completion
        super.init()
        let stop = NSButton(title: "Stop", target: self, action: #selector(stop))
        stop.keyEquivalent = "\r"
        chrome = SessionChrome(screen: screen, rect: rect, color: .systemRed, symbol: "record.circle.fill",
                               buttons: [NSButton(title: "Cancel", target: self, action: #selector(cancel)), stop])
        chrome.status.stringValue = "Recording  0:00"
    }

    func start() {
        chrome.show()
        Task {
            do {
                try FileManager.default.createDirectory(at: Prefs.saveFolder, withIntermediateDirectories: true)
                let url = FileNaming.unique(FileNaming.name(prefix: Prefs.filenamePrefix, ext: "mp4"), in: Prefs.saveFolder)
                let recorder = try await Recorder(screen: screen, rect: rect, to: url)
                try await recorder.start()
                self.recorder = recorder
                // Strong capture is fine: the timer is invalidated when the session ends.
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    MainActor.assumeIsolated { self.tick() }
                }
            } catch {
                fail(error)
            }
        }
    }

    private func tick() {
        let s = Int(Date().timeIntervalSince(startedAt))
        chrome.status.stringValue = "Recording  \(s / 60):\(String(format: "%02d", s % 60))"
    }

    @objc func stop() { end(keep: true) }
    @objc private func cancel() { end(keep: false) }

    private func end(keep: Bool) {
        guard !stopping else { return }
        stopping = true
        timer?.invalidate()
        chrome.status.stringValue = "Saving…"
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
        chrome.close()
        completion(capture)
    }
}

/// MP4 → looping GIF next to it: 12 fps, at most 960 px wide — small enough for
/// GitHub issues and Slack, smooth enough for a UI demo.
enum GIFExport {
    static func make(from video: URL) async throws -> URL {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let fps = 12.0
        var frames: [CGImage] = []
        for i in 0..<max(1, Int(duration * fps)) {
            frames.append(try await generator.image(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600)).image)
        }
        guard let data = GIFEncoder.encode(frames, delay: 1 / fps) else { throw CaptureError.nothingRecorded }
        let url = video.deletingPathExtension().appendingPathExtension("gif")
        try data.write(to: url)
        return url
    }
}
