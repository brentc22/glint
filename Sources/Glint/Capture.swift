import AppKit
import GlintCore
import UniformTypeIdentifiers

/// A finished screenshot and where it went. Everything downstream — quick access,
/// editor, pin — works on this.
@MainActor
final class Capture: ObservableObject {
    @Published private(set) var image: CGImage
    let scale: CGFloat
    private(set) var file: URL?
    /// A window capture without its shadow, so the editor can frame it with a backdrop
    /// instead of stacking a second shadow. Gone once edited: the edit is the new original.
    private(set) var bareWindow: CGImage?

    init(image: CGImage, scale: CGFloat, file: URL? = nil) {
        self.image = image
        self.scale = scale
        self.file = file
    }

    convenience init(window: CGImage, scale: CGFloat) {
        guard Prefs.windowShadow else { self.init(image: window, scale: scale); return }
        self.init(image: Renderer.windowShadow(window, scale: scale), scale: scale)
        bareWindow = window
    }

    /// A screen recording: `file` is the MP4, `image` its first frame.
    var isVideo: Bool { file?.pathExtension.lowercased() == "mp4" }

    /// Size in points — how big it looks on screen and in documents.
    var pointSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }
    var nsImage: NSImage { NSImage(cgImage: image, size: pointSize) }

    /// Swaps in an edited version, rewriting the file and clipboard it already went to.
    func update(_ edited: CGImage) {
        image = edited
        bareWindow = nil
        if let file { try? Self.encode(edited, scale: scale, as: file.pathExtension.lowercased() == "png" ? .png : .jpeg).write(to: file) }
        if Prefs.copyToClipboard { copy() }
    }

    func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if isVideo, let file { pb.writeObjects([file as NSURL]); return }
        // File URL first: Finder, Mail and Slack attach the actual file; PNG for everyone else.
        if let file { pb.writeObjects([file as NSURL]) }
        pb.setData(Self.png(image, scale: scale), forType: .png)
        if let tiff = nsImage.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    @discardableResult
    func save(to folder: URL = Prefs.saveFolder) throws -> URL {
        if let file { return file }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let type: UTType = Prefs.format == .png ? .png : .jpeg
        let url = FileNaming.unique(FileNaming.name(prefix: Prefs.filenamePrefix, ext: type == .png ? "png" : "jpg"), in: folder)
        try Self.encode(image, scale: scale, as: type).write(to: url)
        file = url
        return url
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = FileNaming.name(prefix: Prefs.filenamePrefix)
        panel.directoryURL = Prefs.saveFolder
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let type: UTType = url.pathExtension.lowercased() == "png" ? .png : .jpeg
        try? Self.encode(image, scale: scale, as: type).write(to: url)
    }

    /// PNG with the DPI set to 72 × scale, so a Retina shot shows at its real size in
    /// Preview, Keynote and docs instead of twice as big.
    static func png(_ image: CGImage, scale: CGFloat) -> Data { encode(image, scale: scale, as: .png, allowDownscale: false) }

    /// Honors "Save Retina screenshots at 1×": halves the pixels instead of just the DPI,
    /// for smaller files. Clipboard copies stay full resolution.
    static func encode(_ image: CGImage, scale: CGFloat, as type: UTType, allowDownscale: Bool = true) -> Data {
        if allowDownscale, Prefs.downscaleRetina, scale > 1, let small = Renderer.draw(size: CGSize(
            width: (CGFloat(image.width) / scale).rounded(), height: (CGFloat(image.height) / scale).rounded()), space: image.colorSpace, {
                $0.interpolationQuality = .high
                Renderer.drawImage(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale), $0)
            }) {
            return encode(small, scale: 1, as: type, allowDownscale: false)
        }
        var image = image
        // JPEG has no alpha: a window's transparent corners and shadow margin would turn black.
        if type == .jpeg, let flat = Renderer.draw(size: CGSize(width: image.width, height: image.height), space: image.colorSpace, {
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            $0.setFillColor(.white)
            $0.fill(rect)
            Renderer.drawImage(image, in: rect, $0)
        }) { image = flat }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return Data() }
        let dpi = 72 * scale
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if type == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func playShutter() {
        guard Prefs.playSound else { return }
        NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
                byReference: true)?.play()
    }
}
