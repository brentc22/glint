import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Flattens a screenshot and its annotations into one image.
///
/// Draws in a top-left-origin context (flipped once, up front) so annotation
/// geometry, `CGImage.cropping(to:)` and the editor all share one coordinate space.
public enum Renderer {
    public static func render(_ image: CGImage, annotations: [Annotation],
                              crop: CGRect? = nil, backdrop: Backdrop? = nil, windowShadow: CGFloat? = nil) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        guard let flat = draw(size: size, space: image.colorSpace, { ctx in
            drawImage(image, in: CGRect(origin: .zero, size: size), ctx)
            draw(annotations, over: image, in: ctx)
        }) else { return nil }

        let bounds = CGRect(origin: .zero, size: size)
        let cropped = crop.map { $0.integral.intersection(bounds) }.flatMap { $0.isEmpty ? nil : self.crop(flat, to: $0) } ?? flat
        // A backdrop brings its own shadow; a second one around the window would double up.
        if let backdrop { return framed(cropped, backdrop) }
        return windowShadow.map { self.windowShadow(cropped, scale: $0) } ?? cropped
    }

    /// Draws every annotation into an existing top-left-origin context — the editor
    /// canvas uses this so what you see while editing is exactly what gets exported.
    public static func draw(_ annotations: [Annotation], over image: CGImage, in ctx: CGContext) {
        // The dim goes under everything else, so arrows and labels stay bright on top of it.
        spotlight(annotations.compactMap { if case let .spotlight(r) = $0.kind { r } else { nil } },
                  size: CGSize(width: image.width, height: image.height), ctx)
        for annotation in annotations { draw(annotation, over: image, ctx) }
    }

    // MARK: - Annotations

    private static func draw(_ a: Annotation, over image: CGImage, _ ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let color = a.color.cgColor
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(a.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch a.kind {
        case let .arrow(from, to):
            shadow(ctx, a.lineWidth)
            ctx.addPath(arrowPath(from: from, to: to, width: a.lineWidth))
            ctx.fillPath()
        case let .line(from, to):
            shadow(ctx, a.lineWidth)
            ctx.strokeLineSegments(between: [from, to])
        case let .rectangle(r):
            shadow(ctx, a.lineWidth)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: a.lineWidth, cornerHeight: a.lineWidth, transform: nil))
            ctx.strokePath()
        case let .filledRectangle(r):
            ctx.fill(r)
        case let .ellipse(r):
            shadow(ctx, a.lineWidth)
            ctx.strokeEllipse(in: r)
        case let .highlight(r):
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(a.color.with(alpha: 0.45).cgColor)
            ctx.fill(r)
        case let .pixelate(r):
            pixelate(image, r, ctx)
        case let .blur(r):
            blur(image, r, ctx)
        case .spotlight:
            break  // drawn together, before the rest
        case let .freehand(points):
            guard points.count > 1 else { return }
            shadow(ctx, a.lineWidth)
            ctx.addLines(between: points)
            ctx.strokePath()
        case let .text(string, origin, size):
            drawText(string, at: origin, size: size, color: a.color, ctx)
        case let .counter(n, center):
            let radius = Annotation.counterRadius(a.lineWidth)
            shadow(ctx, a.lineWidth)
            ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            ctx.setShadow(offset: .zero, blur: 0)
            let label = a.color.isLight ? RGBA.black : RGBA.white
            drawText("\(n)", centeredAt: center, size: radius * 1.15, color: label, ctx)
        }
    }

    private static func shadow(_ ctx: CGContext, _ lineWidth: CGFloat) {
        ctx.setShadow(offset: CGSize(width: 0, height: lineWidth * 0.25), blur: lineWidth * 0.9,
                      color: CGColor(gray: 0, alpha: 0.35))
    }

    /// A tapered arrow as one filled shape: thin at the tail, full width at the head —
    /// reads better than a stroked line with a triangle glued on.
    static func arrowPath(from tail: CGPoint, to tip: CGPoint, width: CGFloat) -> CGPath {
        let dx = tip.x - tail.x, dy = tip.y - tail.y
        let length = max(hypot(dx, dy), 0.001)
        let (ux, uy) = (dx / length, dy / length)   // along the arrow
        let (nx, ny) = (-uy, ux)                    // perpendicular
        let headLength = min(max(width * 4.5, 18), length * 0.6)
        let headHalf = headLength * 0.55
        let base = CGPoint(x: tip.x - ux * headLength, y: tip.y - uy * headLength)
        let shaftHead = width * 0.5, shaftTail = width * 0.2

        func p(_ o: CGPoint, _ along: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(x: o.x + ux * along + nx * side, y: o.y + uy * along + ny * side)
        }
        let path = CGMutablePath()
        path.addLines(between: [
            p(tail, 0, shaftTail), p(base, headLength * 0.18, shaftHead), p(base, 0, headHalf), tip,
            p(base, 0, -headHalf), p(base, headLength * 0.18, -shaftHead), p(tail, 0, -shaftTail),
        ])
        path.closeSubpath()
        return path
    }

    /// Pixelates what's under `rect` in the original screenshot: every block becomes the
    /// exact average of its pixels. Averaging (not resampling, which keeps one real pixel
    /// per block) plus blocks that scale with the shorter side — a line of text becomes one
    /// or two rows — leaves nothing to recover, unlike a blur over the real pixels.
    private static func pixelate(_ image: CGImage, _ rect: CGRect, _ ctx: CGContext) {
        guard let grid = BlockGrid(image, rect) else { return }
        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                let i = (row * grid.cols + col) * 4
                let alpha = CGFloat(grid.cells[i + 3]) / 255
                let un = alpha > 0 ? 1 / (alpha * 255) : 0  // un-premultiply for setFillColor
                ctx.setFillColor(CGColor(srgbRed: CGFloat(grid.cells[i]) * un, green: CGFloat(grid.cells[i + 1]) * un,
                                         blue: CGFloat(grid.cells[i + 2]) * un, alpha: alpha))
                ctx.fill(grid.cellRect(col, row))
            }
        }
    }

    /// A blur that is as safe as `pixelate`: it smooths the block averages, never the real
    /// pixels. A Gaussian blur over the original keeps enough of text's shape to read it
    /// back (or to brute-force a short number); this only has one colour per block to work
    /// with, so it looks soft and still hides everything.
    private static func blur(_ image: CGImage, _ rect: CGRect, _ ctx: CGContext) {
        guard let grid = BlockGrid(image, rect), let small = grid.image() else { return }
        let block = CGFloat(grid.block)
        let covered = CGRect(x: 0, y: 0, width: CGFloat(grid.cols) * block, height: CGFloat(grid.rows) * block)
        let soft = CIImage(cgImage: small)
            .samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: block, y: block))
            .clampedToExtent()  // edges blur into themselves, not into transparent black
            .applyingGaussianBlur(sigma: Double(block) * 0.55)
        guard let out = ciContext.createCGImage(soft, from: covered, format: .RGBA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return }
        ctx.saveGState()
        ctx.clip(to: grid.rect)
        drawImage(out, in: CGRect(origin: grid.rect.origin, size: covered.size), ctx)
        ctx.restoreGState()
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Dims the whole image except the spotlit rectangles, in one layer — two spotlights
    /// each leave the other bright instead of dimming it.
    private static func spotlight(_ holes: [CGRect], size: CGSize, _ ctx: CGContext) {
        guard !holes.isEmpty else { return }
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setBlendMode(.clear)
        for hole in holes {
            let radius = min(16, min(hole.width, hole.height) * 0.1)
            ctx.addPath(CGPath(roundedRect: hole, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    static func pixelBlockSize(for rect: CGRect) -> CGFloat {
        min(40, max(10, min(rect.width, rect.height) / 1.5))
    }

    // MARK: - Text

    private static func font(_ size: CGFloat) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        return base
    }

    private static func line(_ string: String, size: CGFloat, color: RGBA) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    /// `origin` is the top-left of the text box.
    private static func drawText(_ string: String, at origin: CGPoint, size: CGFloat, color: RGBA, _ ctx: CGContext) {
        let outline = color.isLight ? RGBA(0, 0, 0, 0.55) : RGBA(1, 1, 1, 0.9)
        ctx.setShadow(offset: .zero, blur: size * 0.12, color: outline.cgColor)
        for (i, row) in string.components(separatedBy: "\n").enumerated() {
            let baseline = CGPoint(x: origin.x, y: origin.y + size * (1.0 + 1.25 * CGFloat(i)))
            drawLine(line(row, size: size, color: color), baseline: baseline, ctx)
        }
    }

    private static func drawText(_ string: String, centeredAt center: CGPoint, size: CGFloat, color: RGBA, _ ctx: CGContext) {
        let l = line(string, size: size, color: color)
        let b = CTLineGetImageBounds(l, ctx)
        drawLine(l, baseline: CGPoint(x: center.x - b.midX, y: center.y + b.midY), ctx)
    }

    /// CoreText draws y-up; un-flip locally around the baseline.
    private static func drawLine(_ line: CTLine, baseline: CGPoint, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: baseline.x, y: baseline.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: - Backdrop

    private static func framed(_ image: CGImage, _ b: Backdrop) -> CGImage {
        let inner = CGSize(width: image.width, height: image.height)
        let pad = b.padding * max(1, inner.width / 1600)  // keep the frame proportional on big shots
        let size = CGSize(width: inner.width + pad * 2, height: inner.height + pad * 2)
        return draw(size: size, space: image.colorSpace) { ctx in
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let gradient = CGGradient(colorsSpace: space, colors: [b.from.cgColor, b.to.cgColor] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])

            let rect = CGRect(x: pad, y: pad, width: inner.width, height: inner.height)
            let shape = CGPath(roundedRect: rect, cornerWidth: b.cornerRadius, cornerHeight: b.cornerRadius, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -pad * 0.2), blur: pad * 0.6, color: CGColor(gray: 0, alpha: 0.35))
            ctx.addPath(shape)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(shape)
            ctx.clip()
            drawImage(image, in: rect, ctx)
        } ?? image
    }

    /// A macOS-style drop shadow on a transparent margin, like the system's own window
    /// screenshots. ScreenCaptureKit returns the bare window.
    public static func windowShadow(_ image: CGImage, scale: CGFloat) -> CGImage {
        let pad = 48 * scale
        let size = CGSize(width: CGFloat(image.width) + pad * 2, height: CGFloat(image.height) + pad * 2)
        return draw(size: size, space: image.colorSpace) { ctx in
            ctx.setShadow(offset: CGSize(width: 0, height: -16 * scale), blur: 40 * scale, color: CGColor(gray: 0, alpha: 0.45))
            drawImage(image, in: CGRect(x: pad, y: pad * 0.7, width: CGFloat(image.width), height: CGFloat(image.height)), ctx)
        } ?? image
    }

    // MARK: - Plumbing

    /// `CGImage.cropping(to:)` is a view that keeps the whole source alive: a small area of a
    /// 3440×1440 screenshot would hold on to all 20 MB for as long as the capture lives.
    /// This copies just the pixels — in the source's own format, so they stay exact — and
    /// the full frame can go.
    public static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        guard let view = image.cropping(to: rect) else { return nil }
        if view.width == image.width, view.height == image.height { return image }  // nothing to free
        let size = CGSize(width: view.width, height: view.height)
        if let space = view.colorSpace, let ctx = CGContext(data: nil, width: view.width, height: view.height,
                                                            bitsPerComponent: view.bitsPerComponent, bytesPerRow: 0,
                                                            space: space, bitmapInfo: view.bitmapInfo.rawValue) {
            ctx.draw(view, in: CGRect(origin: .zero, size: size))
            return ctx.makeImage()
        }
        // A format CGContext can't draw into (e.g. 16-bit float): fall back to 8-bit RGBA.
        return draw(size: size, space: image.colorSpace) { drawImage(view, in: CGRect(origin: .zero, size: size), $0) }
    }

    /// A top-left-origin RGBA context of `size` pixels, in `space` when it's RGB (so Display
    /// P3 captures stay P3) and sRGB otherwise. Note: shadow offsets ignore the flip and stay
    /// y-up, so a shadow that falls down needs a negative height.
    public static func draw(size: CGSize, space: CGColorSpace? = nil, _ body: (CGContext) -> Void) -> CGImage? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func context(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let ctx = space.flatMap({ $0.model == .rgb ? context($0) : nil }) ?? context(srgb) else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        body(ctx)
        return ctx.makeImage()
    }

    /// `CGContext.draw` assumes y-up; flip locally so images land upright in our y-down space.
    public static func drawImage(_ image: CGImage, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }
}

/// The exact per-block averages of one area of a screenshot — the only thing pixelate and
/// blur ever draw, so neither can leak a real pixel.
struct BlockGrid {
    let rect: CGRect
    let block: Int
    let cols: Int, rows: Int
    /// Premultiplied sRGB RGBA, row 0 on top.
    let cells: [UInt8]

    init?(_ image: CGImage, _ area: CGRect) {
        let r = area.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !r.isEmpty, let source = image.cropping(to: r) else { return nil }
        let (w, h) = (source.width, source.height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let bitmap = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bitmap.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))  // row 0 of the buffer = top

        let block = Int(Renderer.pixelBlockSize(for: r))
        let cols = (w + block - 1) / block, rows = (h + block - 1) / block
        var cells = [UInt8](repeating: 0, count: cols * rows * 4)
        for row in 0..<rows {
            for col in 0..<cols {
                let bx = col * block, by = row * block
                let bw = min(block, w - bx), bh = min(block, h - by)
                var sum = [Int](repeating: 0, count: 4)
                for y in by..<(by + bh) {
                    var i = (y * w + bx) * 4
                    for _ in 0..<bw {
                        for c in 0..<4 { sum[c] += Int(pixels[i + c]) }
                        i += 4
                    }
                }
                let n = bw * bh, o = (row * cols + col) * 4
                for c in 0..<4 { cells[o + c] = UInt8((sum[c] + n / 2) / n) }
            }
        }
        self.rect = r
        self.block = block
        self.cols = cols
        self.rows = rows
        self.cells = cells
    }

    /// Cell `(col, row)` in image pixels; the last column and row may be narrower.
    func cellRect(_ col: Int, _ row: Int) -> CGRect {
        let x = rect.minX + CGFloat(col * block), y = rect.minY + CGFloat(row * block)
        return CGRect(x: x, y: y, width: min(CGFloat(block), rect.maxX - x), height: min(CGFloat(block), rect.maxY - y))
    }

    /// One pixel per cell.
    func image() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(cells) as CFData) else { return nil }
        return CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

extension RGBA {
    func with(alpha: CGFloat) -> RGBA { RGBA(r, g, b, alpha) }
    /// Perceived brightness — picks black or white for text on top of this color.
    var isLight: Bool { 0.299 * r + 0.587 * g + 0.114 * b > 0.7 }
}
