// Draws docs/demo-input.png: a fake settings screen full of (made-up) sensitive data,
// for trying the redact feature and for README screenshots. Nothing in it is real.
import AppKit

let size = CGSize(width: 1200, height: 760)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSColor(white: 0.96, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

// Sidebar
NSColor(white: 0.92, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 240, height: size.height).fill()
func text(_ s: String, _ x: CGFloat, _ yTop: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor = .black) {
    let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    NSAttributedString(string: s, attributes: a).draw(at: NSPoint(x: x, y: 760 - yTop - size * 1.2))
}
text("Acme Cloud", 28, 34, 20, .bold)
for (i, item) in ["Overview", "Projects", "Billing", "API keys", "Team", "Settings"].enumerated() {
    if item == "Settings" {
        NSColor.systemBlue.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: NSRect(x: 16, y: 760 - 104 - CGFloat(i) * 40 - 30, width: 208, height: 34), xRadius: 8, yRadius: 8).fill()
    }
    text(item, 32, 104 + CGFloat(i) * 40, 15, item == "Settings" ? .semibold : .regular, item == "Settings" ? .systemBlue : .darkGray)
}

// Card
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 288, y: 60, width: 860, height: 620), xRadius: 16, yRadius: 16).fill()
text("Account settings", 328, 110, 28, .bold)
text("Manage your profile, payouts and API access.", 328, 152, 15, .regular, .gray)

let rows: [(String, String)] = [
    ("Name", "Jan Peeters"),
    ("Email", "jan.peeters@example.com"),
    ("Phone", "+32 470 12 34 56"),
    ("Payout IBAN", "BE68 5390 0754 7034"),
    ("Card on file", "4111 1111 1111 1111"),
    ("Secret API key", "sk-proj-Xa81kQpL0zR4mN7vB2cT9yWd"),
    ("Server", "192.168.1.20"),
    ("Plan", "Team · 12 seats"),
]
for (i, row) in rows.enumerated() {
    let y = 210 + CGFloat(i) * 56
    text(row.0, 328, y, 14, .medium, .gray)
    text(row.1, 560, y - 2, 17, .medium, .black)
    NSColor(white: 0.92, alpha: 1).setFill()
    NSRect(x: 328, y: 760 - y - 30, width: 780, height: 1).fill()
}

NSGraphicsContext.restoreGraphicsState()
let props: [NSBitmapImageRep.PropertyKey: Any] = [:]
var data = rep.representation(using: .png, properties: props)!
// 144 DPI so Glint opens it as a 2× Retina shot.
let source = CGImageSourceCreateWithData(data as CFData, nil)!
let out = NSMutableData()
let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImageFromSource(dest, source, 0, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
CGImageDestinationFinalize(dest)
data = out as Data
try! data.write(to: URL(fileURLWithPath: "docs/demo-input.png"))
