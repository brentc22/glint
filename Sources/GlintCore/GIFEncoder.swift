import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum GIFEncoder {
    /// A looping GIF. `delay` is seconds per frame; GIF timing has 1/100 s steps.
    public static func encode(_ frames: [CGImage], delay: Double) -> Data? {
        guard !frames.isEmpty else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames.count, nil) else { return nil }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay,
                                                          kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        for frame in frames { CGImageDestinationAddImage(dest, frame, frameProps) }
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
