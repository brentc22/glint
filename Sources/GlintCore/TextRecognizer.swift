import CoreGraphics
@preconcurrency import Vision

/// On-device text recognition (Apple Vision) — nothing leaves the Mac.
public enum TextRecognizer {
    public struct Line: Sendable {
        public let text: String
        /// Image pixels, top-left origin.
        public let frame: CGRect
    }

    /// All text in the image, top to bottom. Vision often returns one line in pieces
    /// (a label, then a value); pieces at the same height are joined left to right.
    public static func text(in image: CGImage) async -> String {
        joinRows(await recognize(image).map(\.line))
    }

    static func joinRows(_ lines: [Line]) -> String {
        var rows: [[Line]] = []
        for line in lines.sorted(by: { $0.frame.midY < $1.frame.midY }) {
            if let last = rows.last?.first,
               abs(last.frame.midY - line.frame.midY) < min(last.frame.height, line.frame.height) / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { $0.sorted { $0.frame.minX < $1.frame.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }

    /// Payloads of QR codes and other barcodes in the image.
    public static func barcodes(in image: CGImage) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            let request = VNDetectBarcodesRequest()
            try? VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap(\.payloadStringValue)
        }.value
    }

    /// Pixel rectangles covering sensitive values, padded a little so glyph edges
    /// don't peek out from under the pixelation.
    public static func sensitiveRegions(in image: CGImage,
                                        kinds: Set<SensitiveMatcher.Kind> = Set(SensitiveMatcher.Kind.allCases),
                                        customTerms: [String] = []) async -> [CGRect] {
        await recognize(image).flatMap { result -> [CGRect] in
            SensitiveMatcher.matches(in: result.line.text, kinds: kinds, customTerms: customTerms).compactMap { match in
                guard let box = try? result.candidate.boundingBox(for: match.range)?.boundingBox else { return nil }
                let rect = pixels(box, result.tileSize).offsetBy(dx: 0, dy: CGFloat(result.offsetY))
                let pad = rect.height * 0.2
                return rect.insetBy(dx: -pad, dy: -pad)
            }
        }
    }

    private struct Recognized: @unchecked Sendable {  // VNRecognizedText is immutable once produced
        let line: Line
        let candidate: VNRecognizedText
        /// The candidate's boxes are normalized to its tile: where it starts, how big it is.
        let offsetY: Int
        let tileSize: CGSize
    }

    private static func recognize(_ image: CGImage) async -> [Recognized] {
        await Task.detached(priority: .userInitiated) {
            // Vision scales the whole image to its working size, so on a tall scrolling
            // capture the text ends up too small to read. Tall images go in overlapping
            // tiles; a line found twice in an overlap is kept once.
            var found: [Recognized] = []
            for tile in tiles(width: image.width, height: image.height) {
                guard let piece = image.cropping(to: tile) else { continue }
                for r in recognizeTile(piece) {
                    let frame = r.line.frame.offsetBy(dx: 0, dy: tile.minY)
                    let duplicate = found.contains { $0.line.text == r.line.text && $0.line.frame.intersects(frame) }
                    if !duplicate {
                        found.append(Recognized(line: Line(text: r.line.text, frame: frame), candidate: r.candidate,
                                                offsetY: Int(tile.minY), tileSize: tile.size))
                    }
                }
            }
            return found.sorted { ($0.line.frame.minY, $0.line.frame.minX) < ($1.line.frame.minY, $1.line.frame.minX) }
        }.value
    }

    /// Tiles at most 1.5× as tall as wide (min 1000 px), overlapping by 80 px so no line
    /// is only ever seen cut in half.
    static func tiles(width: Int, height: Int) -> [CGRect] {
        let tileHeight = max(1000, width * 3 / 2)
        guard height > tileHeight else { return [CGRect(x: 0, y: 0, width: width, height: height)] }
        let overlap = 80
        return stride(from: 0, to: height - overlap, by: tileHeight - overlap).map {
            CGRect(x: 0, y: $0, width: width, height: min(tileHeight, height - $0))
        }
    }

    private static func recognizeTile(_ image: CGImage) -> [Recognized] {
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
                              candidate: candidate, offsetY: 0, tileSize: size)
        }
    }

    /// Vision's normalized, bottom-left boxes → image pixels, top-left origin.
    static func pixels(_ box: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
               width: box.width * size.width, height: box.height * size.height)
    }
}
