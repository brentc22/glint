import CoreGraphics
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
            for annotation in annotations { draw(annotation, over: image, ctx) }
        }) else { return nil }

        let bounds = CGRect(origin: .zero, size: size)
        let cropped = crop.map { $0.integral.intersection(bounds) }.flatMap { $0.isEmpty ? nil : flat.cropping(to: $0) } ?? flat
        // A backdrop brings its own shadow; a second one around the window would double up.
        if let backdrop { return framed(cropped, backdrop) }
        return windowShadow.map { self.windowShadow(cropped, scale: $0) } ?? cropped
    }

    /// Draws every annotation into an existing top-left-origin context — the editor
    /// canvas uses this so what you see while editing is exactly what gets exported.
    public static func draw(_ annotations: [Annotation], over image: CGImage, in ctx: CGContext) {
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
    /// or two rows — leaves nothing to recover, unlike a blur.
    private static func pixelate(_ image: CGImage, _ rect: CGRect, _ ctx: CGContext) {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !r.isEmpty, let source = image.cropping(to: r) else { return }
        let (w, h) = (source.width, source.height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let bitmap = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        bitmap.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))  // row 0 of the buffer = top

        let block = Int(pixelBlockSize(for: r))
        for by in stride(from: 0, to: h, by: block) {
            for bx in stride(from: 0, to: w, by: block) {
                let bw = min(block, w - bx), bh = min(block, h - by)
                var sum = [Int](repeating: 0, count: 4)
                for y in by..<(by + bh) {
                    var i = (y * w + bx) * 4
                    for _ in 0..<bw {
                        for c in 0..<4 { sum[c] += Int(pixels[i + c]) }
                        i += 4
                    }
                }
                let n = CGFloat(bw * bh * 255)
                let alpha = CGFloat(sum[3]) / n
                let un = alpha > 0 ? 1 / alpha : 0  // un-premultiply for setFillColor
                ctx.setFillColor(CGColor(srgbRed: CGFloat(sum[0]) / n * un, green: CGFloat(sum[1]) / n * un,
                                         blue: CGFloat(sum[2]) / n * un, alpha: alpha))
                ctx.fill(CGRect(x: r.minX + CGFloat(bx), y: r.minY + CGFloat(by), width: CGFloat(bw), height: CGFloat(bh)))
            }
        }
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

extension RGBA {
    func with(alpha: CGFloat) -> RGBA { RGBA(r, g, b, alpha) }
    /// Perceived brightness — picks black or white for text on top of this color.
    var isLight: Bool { 0.299 * r + 0.587 * g + 0.114 * b > 0.7 }
}
