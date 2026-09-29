@preconcurrency import AVFoundation
import AVKit
import AppKit

/// Cuts the start and end off a recording with QuickTime's own trim bar. The kept part is
/// copied, not re-encoded — instant, and not a pixel worse — and replaces the file.
@MainActor
final class TrimWindow: NSWindow, NSWindowDelegate {
    private static var open: [TrimWindow] = []
    private let capture: Capture
    private let file: URL
    private let playerView = AVPlayerView()

    static func show(_ capture: Capture) {
        guard let file = capture.file, capture.isVideo else { return }
        if let existing = open.first(where: { $0.file == file }) { return existing.makeKeyAndOrderFront(nil) }
        let window = TrimWindow(capture, file: file)
        open.append(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.beginTrimming()
    }

    private init(_ capture: Capture, file: URL) {
        self.capture = capture
        self.file = file
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fit = min(1, screen.width * 0.7 / capture.pointSize.width, screen.height * 0.7 / capture.pointSize.height)
        let size = CGSize(width: max(560, capture.pointSize.width * fit), height: max(360, capture.pointSize.height * fit + 60))
        super.init(contentRect: CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                                       width: size.width, height: size.height),
                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        title = "Trim \(file.lastPathComponent)"
        isReleasedWhenClosed = false
        delegate = self
        playerView.controlsStyle = .inline
        playerView.player = AVPlayer(url: file)
        contentView = playerView
    }

    private func beginTrimming() {
        // The player needs its item loaded before the trim bar can appear.
        Task {
            for _ in 0..<50 where !playerView.canBeginTrimming { try? await Task.sleep(for: .milliseconds(100)) }
            playerView.beginTrimming { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if result == .okButton { self.export() } else { self.close() }
                }
            }
        }
    }

    private func export() {
        guard let item = playerView.player?.currentItem else { return close() }
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
        let range = CMTimeRange(start: start, end: end)
        playerView.player?.pause()
        Toast.show("Trimming…", symbol: "scissors")
        let (file, capture) = (file, capture)
        Task {
            do {
                try await Self.trim(file, to: range)
                let thumb = try await AVAssetImageGenerator(asset: AVURLAsset(url: file)).image(at: .zero).image
                capture.replaceThumbnail(thumb)
                HistoryWindow.refresh()
                Toast.show(String(format: "Trimmed to %.1f s", range.duration.seconds), symbol: "scissors")
            } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            }
            close()
        }
    }

    static func trim(_ url: URL, to range: CMTimeRange) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw CaptureError.nothingRecorded
        }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
        session.timeRange = range
        if #available(macOS 15.0, *) {
            try await session.export(to: temp, as: .mp4)
        } else {
            session.outputURL = temp
            session.outputFileType = .mp4
            await session.export()
            if let error = session.error { throw error }
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        Self.open.removeAll { $0 === self }
    }
}
