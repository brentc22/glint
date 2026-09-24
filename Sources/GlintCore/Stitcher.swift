import CoreGraphics
import Foundation

/// Builds one tall image from frames of a region captured while you scroll.
///
/// Per frame pair it (1) finds rows that stayed put — sticky headers and footers —
/// and leaves them out of the search, (2) finds how far the middle band moved by
/// locating a distinctive row of the new frame in the previous one, verifying the
/// whole overlap, and (3) appends only the rows that scrolled into view. Frames that
/// didn't move, moved up, or can't be matched (scrolled too fast) are skipped.
public struct Stitcher {
    public enum Outcome: Equatable { case appended(Int), unchanged, lost }

    private let width: Int
    private let height: Int
    private var previous: Frame?
    private var header = 0, footer = 0
    private var headerRows: [UInt8] = []   // from the first frame
    private var footerRows: [UInt8] = []   // from the latest frame
    private var content: [UInt8] = []      // the growing middle
    private var started = false

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var totalHeight: Int { (headerRows.count + content.count + footerRows.count) / (width * 4) }

    private struct Frame {
        let pixels: [UInt8]
        let signatures: [[UInt8]]
    }

    @discardableResult
    public mutating func add(_ image: CGImage) -> Outcome {
        guard image.width == width, image.height == height, let frame = Self.frame(image) else { return .lost }
        guard let prev = previous else {
            previous = frame
            content = frame.pixels
            return .appended(height)
        }

        // Sticky bands: rows identical at the same position in both frames.
        let top = (0..<height).prefix { Self.same(prev.signatures[$0], frame.signatures[$0]) }.count
        guard top < height else { return .unchanged }
        let bottom = (0..<height).reversed().prefix { Self.same(prev.signatures[$0], frame.signatures[$0]) }.count
        if !started {
            // Fix the bands on the first real scroll; later frames reuse them.
            header = min(top, height / 3)
            footer = min(bottom, height / 3)
            let rowBytes = width * 4
            headerRows = Array(prev.pixels[0..<header * rowBytes])
            content = Array(prev.pixels[header * rowBytes..<(height - footer) * rowBytes])
            started = true
        }

        guard let shift = offset(from: prev, to: frame) else { return .lost }
        guard shift > 0 else { return .unchanged }
        let rowBytes = width * 4
        let bandEnd = height - footer
        content += frame.pixels[(bandEnd - shift) * rowBytes..<bandEnd * rowBytes]
        footerRows = Array(frame.pixels[bandEnd * rowBytes..<height * rowBytes])
        previous = frame
        return .appended(shift)
    }

    /// How many rows the middle band scrolled (positive = down), or nil if no match.
    private func offset(from prev: Frame, to next: Frame) -> Int? {
        let band = header..<(height - footer)
        guard band.count > 8 else { return nil }
        // Anchor: the most detailed row near the top of the new band, so a match is
        // unambiguous (blank rows match everywhere).
        let searchEnd = band.lowerBound + band.count / 2
        guard let anchor = (band.lowerBound..<searchEnd).max(by: { Self.detail(next.signatures[$0]) < Self.detail(next.signatures[$1]) }),
              Self.detail(next.signatures[anchor]) > 0 else { return nil }

        // Gate: 90 % of overlap rows must mostly match — a floating element (chat bubble,
        // "back to top" button) only covers a few strips of some rows. Choose: the most
        // rows matching *exactly* — in repetitive content (logs, numbered lists) wrong
        // offsets also pass the gate, differing only in a digit or two per line.
        var best: (shift: Int, exact: Int)?
        for candidate in band where Self.same(prev.signatures[candidate], next.signatures[anchor]) {
            let shift = candidate - anchor
            guard shift >= 0 else { continue }
            let overlap = band.count - shift
            guard overlap >= band.count / 5 else { continue }
            var mostly = 0, exact = 0
            for i in 0..<overlap {
                let a = prev.signatures[band.lowerBound + i + shift], b = next.signatures[band.lowerBound + i]
                if Self.mostlySame(a, b) { mostly += 1 }
                if Self.exact(a, b) { exact += 1 }
            }
            guard mostly * 10 >= overlap * 9 else { continue }
            // Compare as a share of the overlap, so a tiny overlap can't win on count.
            let score = exact * 1000 / overlap
            if best.map({ score > $0.exact }) ?? true { best = (shift, score) }
        }
        return best?.shift
    }

    public func image() -> CGImage? {
        let pixels = headerRows + content + footerRows
        let rows = pixels.count / (width * 4)
        guard rows > 0 else { return nil }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Row signatures

    private static let columns = 96

    private static func frame(_ image: CGImage) -> Frame? {
        let (w, h) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Per row: average luminance of `columns` vertical strips.
        let strip = max(1, w / columns)
        let signatures = (0..<h).map { y -> [UInt8] in
            (0..<columns).map { c in
                var sum = 0, n = 0
                var x = c * strip
                let end = min(w, x + strip)
                while x < end {
                    let i = (y * w + x) * 4
                    sum += (Int(pixels[i]) * 3 + Int(pixels[i + 1]) * 6 + Int(pixels[i + 2])) / 10
                    n += 1
                    x += 1
                }
                return UInt8(n > 0 ? sum / n : 0)
            }
        }
        return Frame(pixels: pixels, signatures: signatures)
    }

    private static func distance(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var d = 0
        for i in a.indices { d += abs(Int(a[i]) - Int(b[i])) }
        return d / a.count
    }

    private static func same(_ a: [UInt8], _ b: [UInt8]) -> Bool { distance(a, b) <= 1 }

    private static func exact(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > 1 { return false }
        return true
    }

    private static func mostlySame(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var equal = 0
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) <= 2 { equal += 1 }
        return equal * 100 >= a.count * 85
    }

    /// How much a row varies across its width — 0 for a flat, blank row.
    private static func detail(_ s: [UInt8]) -> Int {
        zip(s, s.dropFirst()).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
    }
}
