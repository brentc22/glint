@preconcurrency import AVFoundation
import AppKit
@preconcurrency import ScreenCaptureKit

/// Records a region of a screen to an H.264 MP4 via ScreenCaptureKit. Frames arrive on a
/// private queue and go straight into AVAssetWriter; nothing is held in memory.
final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    // @unchecked: `writer`, `input` and `started` are only touched on `queue`.
    private let queue = DispatchQueue(label: "glint.recorder")
    private let stream: SCStream
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false
    let url: URL

    @MainActor
    init(screen: NSScreen, rect: CGRect, to url: URL) async throws {
        guard Capturer.hasPermission else { throw CaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.permissionDenied
        }
        let own = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let scale = screen.backingScaleFactor
        // H.264 wants even dimensions.
        let width = Int(rect.width * scale) & ~1, height = Int(rect.height * scale) & ~1

        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true  // recordings are usually demos; the pointer tells the story
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6

        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 6],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: own), configuration: config, delegate: nil)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func start() async throws {
        try await stream.startCapture()
    }

    /// Stops and finishes the file; returns once the MP4 is complete on disk.
    func stop() async throws -> URL {
        try? await stream.stopCapture()
        let hadFrames: Bool = queue.sync { started }
        guard hadFrames else {
            writer.cancelWriting()
            throw CaptureError.nothingRecorded
        }
        // ScreenCaptureKit sends frames only when something changes; a still screen gives
        // one frame and then silence. End the session at "now" so the last frame holds
        // until Stop — otherwise ten seconds of a still screen become a 0.1 s video.
        // Frame timestamps use the host clock, so "now" is on the same timeline.
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.writer.endSession(atSourceTime: end)
                self.input.markAsFinished()
                self.writer.finishWriting { done.resume() }
            }
        }
        if let error = writer.error { throw error }
        return url
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, Self.isCompleteFrame(buffer) else { return }
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData { input.append(buffer) }
    }

    /// ScreenCaptureKit also delivers "idle" and "blank" status buffers without pixels.
    private static func isCompleteFrame(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }
}
