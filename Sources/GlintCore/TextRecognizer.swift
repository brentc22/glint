import CoreGraphics
@preconcurrency import Vision

/// On-device text recognition (Apple Vision) — nothing leaves the Mac.
public enum TextRecognizer {
    public struct Line: Sendable {
        public let text: String
        /// Image pixels, top-left origin.
        public let frame: CGRect
    }

    /// All text in the image, top to bottom, one entry per line.
    public static func text(in image: CGImage) async -> String {
        await recognize(image).map(\.line.text).joined(separator: "\n")
    }

    /// Pixel rectangles covering sensitive values, padded a little so glyph edges
    /// don't peek out from under the pixelation.
    public static func sensitiveRegions(in image: CGImage,
                                        kinds: Set<SensitiveMatcher.Kind> = Set(SensitiveMatcher.Kind.allCases)) async -> [CGRect] {
        let size = CGSize(width: image.width, height: image.height)
        return await recognize(image).flatMap { result -> [CGRect] in
            SensitiveMatcher.matches(in: result.line.text, kinds: kinds).compactMap { match in
                guard let box = try? result.candidate.boundingBox(for: match.range)?.boundingBox else { return nil }
                let rect = pixels(box, size)
                let pad = rect.height * 0.2
                return rect.insetBy(dx: -pad, dy: -pad)
            }
        }
    }

    private struct Recognized: @unchecked Sendable {  // VNRecognizedText is immutable once produced
        let line: Line
        let candidate: VNRecognizedText
    }

    private static func recognize(_ image: CGImage) async -> [Recognized] {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // Correction "fixes" codes, keys and IBANs into dictionary words.
            request.usesLanguageCorrection = false
            request.automaticallyDetectsLanguage = true
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let size = CGSize(width: image.width, height: image.height)
            return (request.results ?? []).compactMap { observation -> Recognized? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return Recognized(line: Line(text: candidate.string, frame: pixels(observation.boundingBox, size)),
                                  candidate: candidate)
            }
            .sorted { ($0.line.frame.minY, $0.line.frame.minX) < ($1.line.frame.minY, $1.line.frame.minX) }
        }.value
    }

    /// Vision's normalized, bottom-left boxes → image pixels, top-left origin.
    static func pixels(_ box: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
               width: box.width * size.width, height: box.height * size.height)
    }
}
