// Renders Resources/Glint.iconset (then `make icon` turns it into Glint.icns).
import AppKit

let iconset = URL(fileURLWithPath: "Resources/Glint.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGradient(colors: [NSColor(red: 0.30, green: 0.20, blue: 0.95, alpha: 1),
                        NSColor(red: 0.95, green: 0.35, blue: 0.55, alpha: 1)])!.draw(in: shape, angle: 60)

    // Viewfinder corner brackets.
    let frame = body.insetBy(dx: body.width * 0.2, dy: body.width * 0.2)
    let arm = frame.width * 0.28, w = s * 0.045
    NSColor.white.setStroke()
    let brackets = NSBezierPath()
    brackets.lineWidth = w
    brackets.lineCapStyle = .round
    brackets.lineJoinStyle = .round
    for (x, y, dx, dy) in [(frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0),
                           (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0)] {
        brackets.move(to: NSPoint(x: x + dx * arm, y: y))
        brackets.line(to: NSPoint(x: x, y: y))
        brackets.line(to: NSPoint(x: x, y: y + dy * arm))
    }
    brackets.stroke()

    // The glint: a four-point sparkle in the middle.
    let c = NSPoint(x: frame.midX, y: frame.midY), r = frame.width * 0.3, k = r * 0.16
    let star = NSBezierPath()
    star.move(to: NSPoint(x: c.x, y: c.y + r))
    star.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + k, y: c.y + k), controlPoint2: NSPoint(x: c.x + k, y: c.y + k))
    star.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + k, y: c.y - k), controlPoint2: NSPoint(x: c.x + k, y: c.y - k))
    star.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - k, y: c.y - k), controlPoint2: NSPoint(x: c.x - k, y: c.y - k))
    star.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - k, y: c.y + k), controlPoint2: NSPoint(x: c.x - k, y: c.y + k))
    NSColor.white.setFill()
    star.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for px in [16, 32, 64, 128, 256, 512, 1024] {
    let data = render(px)
    if px <= 512 { try data.write(to: iconset.appendingPathComponent("icon_\(px)x\(px).png")) }
    if px >= 32 { try data.write(to: iconset.appendingPathComponent("icon_\(px / 2)x\(px / 2)@2x.png")) }
}
