// Renders Resources/Glint.iconset (then `make icon` turns it into Glint.icns):
// a camera lens on a sunset gradient, with a glint on the glass.
import AppKit

let iconset = URL(fileURLWithPath: "Resources/Glint.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func squircle(_ s: CGFloat) -> NSBezierPath {
    let inset = s * 100 / 1024
    let r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    return NSBezierPath(roundedRect: r, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
}
func sparkle(_ c: NSPoint, _ r: CGFloat, pinch: CGFloat = 0.16) -> NSBezierPath {
    let k = r * pinch, p = NSBezierPath()
    p.move(to: NSPoint(x: c.x, y: c.y + r))
    p.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + k, y: c.y + k), controlPoint2: NSPoint(x: c.x + k, y: c.y + k))
    p.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + k, y: c.y - k), controlPoint2: NSPoint(x: c.x + k, y: c.y - k))
    p.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - k, y: c.y - k), controlPoint2: NSPoint(x: c.x - k, y: c.y - k))
    p.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - k, y: c.y + k), controlPoint2: NSPoint(x: c.x - k, y: c.y + k))
    return p
}
func rgb(_ h: Int) -> NSColor { NSColor(srgbRed: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1) }

func lens(_ s: CGFloat) {
    let body = squircle(s)
    NSGradient(colors: [rgb(0xFF7A59), rgb(0xFF4E8A), rgb(0x7B5CFF)])!.draw(in: body, angle: -60)
    let c = NSPoint(x: s / 2, y: s / 2)
    let ring = s * 0.30
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.shadowBlurRadius = s * 0.04; sh.shadowOffset = NSSize(width: 0, height: -s * 0.015); sh.set()
    NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let glass = ring * 0.8
    NSGradient(colors: [rgb(0x2A1B5C), rgb(0x0E0A24)])!.draw(in: NSBezierPath(ovalIn: NSRect(x: c.x - glass, y: c.y - glass, width: glass * 2, height: glass * 2)), angle: -90)
    let inner = glass * 0.55
    NSGradient(colors: [rgb(0x5B3FD9).withAlphaComponent(0.9), rgb(0x1A1040)])!.draw(in: NSBezierPath(ovalIn: NSRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2)), relativeCenterPosition: NSPoint(x: -0.3, y: 0.3))
    NSColor.white.setFill()
    sparkle(NSPoint(x: c.x + glass * 0.32, y: c.y + glass * 0.32), glass * 0.42).fill()
    NSColor.white.withAlphaComponent(0.8).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - glass * 0.45, y: c.y - glass * 0.5, width: glass * 0.16, height: glass * 0.16)).fill()
}


func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    lens(CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for px in [16, 32, 64, 128, 256, 512, 1024] {
    let data = render(px)
    if px <= 512 { try data.write(to: iconset.appendingPathComponent("icon_\(px)x\(px).png")) }
    if px >= 32 { try data.write(to: iconset.appendingPathComponent("icon_\(px / 2)x\(px / 2)@2x.png")) }
}
