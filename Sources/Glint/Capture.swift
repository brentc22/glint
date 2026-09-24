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

    init(image: CGImage, scale: CGFloat, file: URL? = nil) {
        self.image = image
        self.scale = scale
        self.file = file
    }

    /// Size in points — how big it looks on screen and in documents.
    var pointSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }
    var nsImage: NSImage { NSImage(cgImage: image, size: pointSize) }

    /// Swaps in an edited version, rewriting the file and clipboard it already went to.
    func update(_ edited: CGImage) {
        image = edited
        if let file { try? Self.png(edited, scale: scale).write(to: file) }
        if Prefs.copyToClipboard { copy() }
    }

    func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        // File URL first: Finder, Mail and Slack attach the actual file; PNG for everyone else.
        if let file { pb.writeObjects([file as NSURL]) }
        pb.setData(Self.png(image, scale: scale), forType: .png)
        if let tiff = nsImage.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    @discardableResult
    func save(to folder: URL = Prefs.saveFolder) throws -> URL {
        if let file { return file }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = FileNaming.unique(FileNaming.name(), in: folder)
        try Self.png(image, scale: scale).write(to: url)
        file = url
        return url
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = FileNaming.name()
        panel.directoryURL = Prefs.saveFolder
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let type: UTType = url.pathExtension.lowercased() == "png" ? .png : .jpeg
        try? Self.encode(image, scale: scale, as: type).write(to: url)
    }

    /// PNG with the DPI set to 72 × scale, so a Retina shot shows at its real size in
    /// Preview, Keynote and docs instead of twice as big.
    static func png(_ image: CGImage, scale: CGFloat) -> Data { encode(image, scale: scale, as: .png) }

    static func encode(_ image: CGImage, scale: CGFloat, as type: UTType) -> Data {
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
