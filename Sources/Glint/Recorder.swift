@preconcurrency import AVFoundation
import AppKit
@preconcurrency import ScreenCaptureKit

/// Records a region of a screen to an H.264 MP4 via ScreenCaptureKit, with system audio
/// and the microphone as AAC tracks when asked. Buffers arrive on a private queue and go
/// straight into AVAssetWriter; nothing is held in memory.
final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Options {
        var fps = 30
        var systemAudio = false
        var microphone = false
        var showsCursor = true
        /// Glint windows that belong in the video: click rings, keystrokes, the webcam.
        var keep: Set<CGWindowID> = []
    }

    // @unchecked: everything below `queue` is only touched on `queue`.
    private let queue = DispatchQueue(label: "glint.recorder")
    private let stream: SCStream
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private var started = false
    /// Paused time so far; every later buffer is moved back by this much, so the video
    /// runs on without a gap.
    private var offset = CMTime.zero
    private var pausedAt: CMTime?
    let url: URL

    /// Two audio tracks play as one only in some players; `stop()` mixes them down.
    var needsMixdown: Bool { systemAudio != nil && microphone != nil }

    @MainActor
    init(screen: NSScreen, rect: CGRect, to url: URL, options: Options) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.permissionDenied
        }
        let scale = screen.backingScaleFactor
        // H.264 wants even dimensions.
        let width = Int(rect.width * scale) & ~1, height = Int(rect.height * scale) & ~1

        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.showsCursor = options.showsCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 8
        config.capturesAudio = options.systemAudio
        config.excludesCurrentProcessAudio = true  // no shutter sounds or toasts in the soundtrack
        config.sampleRate = 48_000
        config.channelCount = 2
        let mic = options.microphone && Self.canRecordMicrophone
        if #available(macOS 15.0, *), mic { config.captureMicrophone = true }

        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * (options.fps > 30 ? 9 : 6),
                AVVideoExpectedSourceFrameRateKey: options.fps,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        systemAudio = options.systemAudio ? Self.audioInput() : nil
        microphone = mic ? Self.audioInput() : nil
        for input in [systemAudio, microphone].compactMap({ $0 }) { writer.add(input) }

        let filter = SCContentFilter(display: display, excludingWindows: Capturer.hidden(in: content, keep: options.keep))
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if options.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if #available(macOS 15.0, *), mic { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
    }

    /// ScreenCaptureKit records the microphone from macOS 15 on.
    static var canRecordMicrophone: Bool {
        if #available(macOS 15.0, *) { return true } else { return false }
    }

    private static func audioInput() -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000,
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    func start() async throws {
        try await stream.startCapture()
    }

    func pause() {
        queue.async { if self.pausedAt == nil { self.pausedAt = Self.now } }
    }

    func resume() {
        queue.async {
            guard let at = self.pausedAt else { return }
            self.offset = self.offset + (Self.now - at)
            self.pausedAt = nil
        }
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
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                let end = (self.pausedAt ?? Self.now) - self.offset
                self.writer.endSession(atSourceTime: end)
                [self.video, self.systemAudio, self.microphone].compactMap { $0 }.forEach { $0.markAsFinished() }
                self.writer.finishWriting { done.resume() }
            }
        }
        if let error = writer.error { throw error }
        if needsMixdown { try await AudioMixdown.run(url) }
        return url
    }

    private static var now: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid, pausedAt == nil else { return }
        switch type {
        case .screen:
            guard Self.isCompleteFrame(buffer) else { return }
            if !started {
                guard writer.startWriting() else { return }
                writer.startSession(atSourceTime: buffer.presentationTimeStamp)
                started = true
            }
            append(buffer, to: video)
        case .audio:
            if started, let systemAudio { append(buffer, to: systemAudio) }
        default:
            // `.microphone` only exists in the macOS 15 SDK; it's the one other type we ask for.
            if started, let microphone { append(buffer, to: microphone) }
        }
    }

    private func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput) {
        guard input.isReadyForMoreMediaData, let shifted = Self.shift(buffer, by: offset) else { return }
        input.append(shifted)
    }

    /// The same buffer, `offset` earlier.
    private static func shift(_ buffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return buffer }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - offset
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - offset }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    /// ScreenCaptureKit also delivers "idle" and "blank" status buffers without pixels.
    private static func isCompleteFrame(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }
}

/// Mixes a recording's system audio and microphone tracks into one. Browsers, Slack and
/// most players only play the first audio track, so without this the voice-over would
/// silently go missing. The video is copied as is, not re-encoded.
enum AudioMixdown {
    static func run(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard audio.count > 1, let track = try await asset.loadTracks(withMediaType: .video).first else { return }
        let hint = try await track.load(.formatDescriptions).first

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(videoOut)
        reader.add(audioOut)

        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: temp, fileType: .mp4)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000,
        ])
        writer.add(videoIn)
        writer.add(audioIn)

        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? CaptureError.nothingRecorded
        }
        writer.startSession(atSourceTime: .zero)
        let (video, sound) = (Pump(output: videoOut, input: videoIn), Pump(output: audioOut, input: audioIn))
        async let v: Void = pump(video, label: "video")
        async let a: Void = pump(sound, label: "audio")
        _ = await (v, a)
        await writer.finishWriting()
        guard writer.status == .completed, reader.status == .completed else {
            try? FileManager.default.removeItem(at: temp)
            throw writer.error ?? reader.error ?? CaptureError.nothingRecorded
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    private static func pump(_ box: Pump, label: String) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            box.input.requestMediaDataWhenReady(on: DispatchQueue(label: "glint.mixdown.\(label)")) {
                while box.input.isReadyForMoreMediaData {
                    guard let buffer = box.output.copyNextSampleBuffer() else {
                        box.input.markAsFinished()
                        done.resume()
                        return
                    }
                    box.input.append(buffer)
                }
            }
        }
    }

    /// Reader output and writer input used from their own serial queue only.
    private final class Pump: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        init(output: AVAssetReaderOutput, input: AVAssetWriterInput) { self.output = output; self.input = input }
    }
}
