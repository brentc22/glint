import CoreGraphics
import ImageIO
import Foundation
@testable import GlintCore

// Line-buffer stdout so CI logs show which test was running if one hangs.
setvbuf(stdout, nil, _IOLBF, 0)

func kinds(_ text: String) -> [SensitiveMatcher.Kind] { SensitiveMatcher.matches(in: text).map(\.kind) }
func matched(_ text: String) -> [String] { SensitiveMatcher.matches(in: text).map { String(text[$0.range]) } }

print("SensitiveMatcher")
T.test("email") {
    T.equal(matched("mail brent.c+test@vernast.be now"), ["brent.c+test@vernast.be"])
}
T.test("IBAN with valid checksum, spaced or compact") {
    T.equal(kinds("IBAN BE68 5390 0754 7034"), [.iban])
    T.equal(kinds("NL91ABNA0417164300"), [.iban])
}
T.test("IBAN with a wrong checksum is ignored") {
    T.equal(kinds("BE69 5390 0754 7034"), [])
}
T.test("card numbers need a valid Luhn checksum") {
    T.equal(kinds("card 4111 1111 1111 1111"), [.card])
    T.equal(kinds("order 4111 1111 1111 1112"), [])
}
T.test("phone numbers, international and local") {
    T.equal(matched("bel +32 470 12 34 56 of 0470/12.34.56"), ["+32 470 12 34 56", "0470/12.34.56"])
}
T.test("dates, times, prices and versions are not phone numbers") {
    T.equal(kinds("2026-09-24 15:04 € 1.429,57 v2.1.281 build 20312077"), [])
}
T.test("API keys and tokens") {
    T.equal(kinds("OPENAI=sk-proj-abcdEFGH1234ijklMNOP5678qrst"), [.apiKey])
    T.equal(kinds("ghp_abcdefghijklmnopqrstuvwxyz0123456789"), [.apiKey])
    T.equal(kinds("AKIAIOSFODNN7EXAMPLE"), [.apiKey])
    T.equal(kinds("sk_live_51HxYzAbCdEfGhIjKl"), [.apiKey])
}
T.test("JWT") {
    T.equal(kinds("Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.abcdefghijklmnop"), [.jwt])
}
T.test("IP address, but not an out-of-range one") {
    T.equal(kinds("host 192.168.1.20"), [.ipAddress])
    T.equal(kinds("999.1.1.1"), [])
}
T.test("overlapping patterns report once") {
    T.equal(SensitiveMatcher.matches(in: "BE68 5390 0754 7034").count, 1)
}

print("Document")
let white = Renderer.draw(size: CGSize(width: 400, height: 200)) { ctx in
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
}!
T.test("undo and redo restore whole states") {
    var doc = Document(image: white)
    doc.add(Annotation(.rectangle(CGRect(x: 10, y: 10, width: 50, height: 50))))
    doc.add(Annotation(.counter(1, at: CGPoint(x: 100, y: 100))))
    T.equal(doc.annotations.count, 2)
    doc.undo()
    T.equal(doc.annotations.count, 1)
    doc.redo()
    T.equal(doc.annotations.count, 2)
    doc.undo(); doc.undo()
    T.equal(doc.canUndo, false)
    doc.add(Annotation(.line(from: .zero, to: CGPoint(x: 5, y: 5))))
    T.equal(doc.canRedo, false, "a new edit clears redo:")
}
T.test("a no-op change doesn't create an undo step") {
    var doc = Document(image: white)
    doc.apply { _ in }
    T.equal(doc.canUndo, false)
}
T.test("counter numbers continue from the highest") {
    var doc = Document(image: white)
    T.equal(doc.nextCounter, 1)
    doc.add(Annotation(.counter(1, at: .zero)))
    doc.add(Annotation(.counter(4, at: .zero)))
    T.equal(doc.nextCounter, 5)
}
T.test("hit-testing picks the topmost annotation") {
    var doc = Document(image: white)
    let bottom = Annotation(.rectangle(CGRect(x: 0, y: 0, width: 100, height: 100)))
    let top = Annotation(.ellipse(CGRect(x: 20, y: 20, width: 40, height: 40)))
    doc.add(bottom); doc.add(top)
    T.equal(doc.hit(CGPoint(x: 30, y: 30))?.id, top.id)
    T.equal(doc.hit(CGPoint(x: 90, y: 90))?.id, bottom.id)
    T.expect(doc.hit(CGPoint(x: 300, y: 150)) == nil, "empty spot hits nothing")
}
T.test("moving an annotation shifts all of its geometry") {
    let a = Annotation(.arrow(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 3, y: 4))).offset(by: CGSize(width: 10, height: 20))
    T.equal(a.kind, .arrow(from: CGPoint(x: 11, y: 22), to: CGPoint(x: 13, y: 24)))
}

print("Renderer")
func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // y-down → CGContext's y-up.
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return data
}
T.test("filled rectangle lands where it was drawn, top-left origin") {
    let out = Renderer.render(white, annotations: [Annotation(.filledRectangle(CGRect(x: 0, y: 0, width: 50, height: 20)), color: .black)])!
    T.equal(pixel(out, 10, 10)[0] < 50, true, "inside is black:")
    T.equal(pixel(out, 10, 150)[0], 255, "below is still white:")
}
T.test("pixelate replaces detail with blocks") {
    // Checkerboard of 2px squares; pixelating averages it to flat grey.
    let checker = Renderer.draw(size: CGSize(width: 100, height: 100)) { ctx in
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        for x in stride(from: 0, to: 100, by: 2) { for y in stride(from: 0, to: 100, by: 2) where (x + y) % 4 == 0 {
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
        } }
    }!
    let out = Renderer.render(checker, annotations: [Annotation(.pixelate(CGRect(x: 0, y: 0, width: 100, height: 100)))])!
    let a = pixel(out, 10, 10)[0], b = pixel(out, 11, 10)[0]
    T.equal(a, b, "neighbouring pixels in one block are equal:")
    T.expect(a > 40 && a < 215, "block is a mix, not pure black/white (\(a))")
}
T.test("crop and backdrop change the output size") {
    let cropped = Renderer.render(white, annotations: [], crop: CGRect(x: 10, y: 10, width: 100, height: 50))!
    T.equal([cropped.width, cropped.height], [100, 50])
    let framed = Renderer.render(white, annotations: [], backdrop: Backdrop(from: .red, to: .blue, padding: 40))!
    T.equal([framed.width, framed.height], [480, 280])
}
T.test("arrow shape ends at its tip") {
    let path = Renderer.arrowPath(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 0), width: 6)
    T.expect(path.contains(CGPoint(x: 195, y: 0)), "near the tip is filled")
    T.expect(!path.contains(CGPoint(x: 205, y: 0)), "past the tip is empty")
}

print("TextRecognizer (Vision, on-device)")
T.test("finds an email in rendered text and returns its box") {
    let big = Renderer.draw(size: CGSize(width: 900, height: 200)) { ctx in
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 200))
    }!
    let image = Renderer.render(big, annotations: [
        Annotation(.text("Contact: jan.peeters@example.com", at: CGPoint(x: 40, y: 60), size: 40), color: .black)
    ])!
    let sema = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var regions: [CGRect] = []
    nonisolated(unsafe) var text = ""
    Task.detached {
        text = await TextRecognizer.text(in: image)
        regions = await TextRecognizer.sensitiveRegions(in: image)
        sema.signal()
    }
    sema.wait()
    T.expect(text.contains("jan.peeters@example.com"), "OCR read: \(text)")
    T.equal(regions.count, 1)
    if let r = regions.first {
        // The email starts after "Contact: ", so the box must not cover the label.
        T.expect(r.minX > 150 && r.maxX > 500 && r.minY < 110 && r.maxY > 70, "box \(r)")
    }
}

T.test("redacts exactly the six sensitive values on the demo screen") {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../docs/demo-input.png").standardizedFileURL
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return T.expect(false, "missing \(url.path)")
    }
    let sema = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var regions: [CGRect] = []
    Task.detached { regions = await TextRecognizer.sensitiveRegions(in: image); sema.signal() }
    sema.wait()
    // email, phone, IBAN, card, API key, IP — not the name, the plan or the labels.
    T.equal(regions.count, 6)
    // Every value sits in the right-hand column (x ≥ 1100 px at 2×).
    T.expect(regions.allSatisfy { $0.minX > 1000 }, "a label got redacted: \(regions)")
}

print("FileNaming")
T.test("dated name and unique suffix") {
    let date = ISO8601DateFormatter().date(from: "2026-09-24T13:04:12Z")!
    T.expect(FileNaming.name(for: date).hasPrefix("Glint 2026-09-24 at "), FileNaming.name(for: date))
    let dir = URL(fileURLWithPath: "/tmp/x")
    let taken: Set<String> = ["/tmp/x/a.png", "/tmp/x/a 2.png"]
    T.equal(FileNaming.unique("a.png", in: dir) { taken.contains($0.path) }.lastPathComponent, "a 3.png")
}

T.finish()
