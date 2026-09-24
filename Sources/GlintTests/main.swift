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

T.test("custom terms: plain words case-insensitive, /regex/ as pattern") {
    let text = "Klant ACME-2291 van Vettenburg bv"
    T.equal(SensitiveMatcher.matches(in: text, customTerms: ["vettenburg"]).map { String(text[$0.range]) }, ["Vettenburg"])
    T.equal(SensitiveMatcher.matches(in: text, customTerms: ["/ACME-\\d+/"]).map { String(text[$0.range]) }, ["ACME-2291"])
    T.equal(SensitiveMatcher.matches(in: text, kinds: [.email], customTerms: ["Vettenburg"]).count, 0, "custom off:")
    T.equal(SensitiveMatcher.matches(in: text, customTerms: ["/[/", "  "]).count, 0, "broken regex and blanks ignored:")
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
T.test("window shadow falls below the window, on a transparent margin") {
    let window = Renderer.draw(size: CGSize(width: 200, height: 100)) { $0.setFillColor(.white); $0.fill(CGRect(x: 0, y: 0, width: 200, height: 100)) }!
    let out = Renderer.windowShadow(window, scale: 1)
    T.equal([out.width, out.height], [296, 196])
    let top = Int(48 * 0.7), below = top + 100
    T.equal(pixel(out, 1, 1)[3], 0, "corner stays transparent:")
    T.equal(pixel(out, 148, top + 50)[0], 255, "window itself is untouched:")
    let above = pixel(out, 148, top - 8)[3], under = pixel(out, 148, below + 8)[3]
    T.expect(under > above, "shadow is heavier below (\(under)) than above (\(above))")
    T.expect(pixel(out, 148, 195)[3] < 20, "and fades out before the bottom edge")
}
T.test("window shadow keeps Display P3") {
    let p3 = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    T.equal(Renderer.windowShadow(p3, scale: 1).colorSpace?.name, CGColorSpace.displayP3)
}
T.test("a backdrop replaces the window shadow instead of stacking on it") {
    let doc = Document(image: white, scale: 1, windowShadow: true)
    T.equal(doc.render()!.width, 496)
    var framed = doc
    framed.apply { $0.backdrop = Backdrop(from: .red, to: .blue, padding: 40) }
    T.equal(framed.render()!.width, 480)
}
T.test("arrow shape ends at its tip") {
    let path = Renderer.arrowPath(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 0), width: 6)
    T.expect(path.contains(CGPoint(x: 195, y: 0)), "near the tip is filled")
    T.expect(!path.contains(CGPoint(x: 205, y: 0)), "past the tip is empty")
}

print("Stitcher (scrolling capture)")
/// A deterministic "web page": rows of text-like dashes, varying per row.
func page(width: Int, height: Int, seed: UInt64) -> CGImage {
    var rng = seed
    func next() -> UInt64 { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return rng >> 33 }
    return Renderer.draw(size: CGSize(width: width, height: height)) { ctx in
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for y in stride(from: 0, to: height, by: 3) where next() % 3 != 0 {
            var x = Int(next() % 20)
            while x < width - 10 {
                let w = 4 + Int(next() % 40)
                ctx.setFillColor(CGColor(gray: CGFloat(next() % 180) / 255, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: w, height: 2))
                x += w + 3 + Int(next() % 12)
            }
        }
    }!
}
/// What the screen shows with the page scrolled to `offset`, under a sticky header and footer.
func viewport(_ page: CGImage, offset: Int, width: Int, height: Int, header: Int, footer: Int) -> CGImage {
    Renderer.draw(size: CGSize(width: width, height: height)) { ctx in
        let band = page.cropping(to: CGRect(x: 0, y: offset, width: width, height: height - header - footer))!
        Renderer.drawImage(band, in: CGRect(x: 0, y: header, width: width, height: height - header - footer), ctx)
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.3, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: header))
        ctx.setFillColor(CGColor(gray: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: height - footer, width: width, height: footer))
        if header > 0 { ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 20, y: 18, width: 90, height: 12)) }  // "logo"
    }!
}
func bytes(_ image: CGImage) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let ctx = CGContext(data: &b, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return b
}
T.test("stitches a page under a sticky header and footer, pixel for pixel") {
    let (w, h, header, footer) = (400, 600, 60, 40)
    let full = page(width: w, height: 3000, seed: 7)
    var stitcher = Stitcher(width: w, height: h)
    var outcomes: [Stitcher.Outcome] = []
    for offset in [0, 0, 120, 260, 400, 555, 700, 701, 900] {
        outcomes.append(stitcher.add(viewport(full, offset: offset, width: w, height: h, header: header, footer: footer)))
    }
    T.equal(outcomes, [.appended(600), .unchanged, .appended(120), .appended(140), .appended(140), .appended(155),
                       .appended(145), .appended(1), .appended(199)])
    let band = h - header - footer
    let expected = viewport(full, offset: 0, width: w, height: 900 + band + header + footer, header: header, footer: footer)
    // Build the expectation from real content: header + page[0 ..< 900+band] + footer.
    let want = Renderer.draw(size: CGSize(width: w, height: header + 900 + band + footer)) { ctx in
        Renderer.drawImage(viewport(full, offset: 0, width: w, height: h, header: header, footer: footer).cropping(to: CGRect(x: 0, y: 0, width: w, height: header))!,
                           in: CGRect(x: 0, y: 0, width: w, height: header), ctx)
        Renderer.drawImage(full.cropping(to: CGRect(x: 0, y: 0, width: w, height: 900 + band))!, in: CGRect(x: 0, y: header, width: w, height: 900 + band), ctx)
        Renderer.drawImage(expected.cropping(to: CGRect(x: 0, y: expected.height - footer, width: w, height: footer))!,
                           in: CGRect(x: 0, y: header + 900 + band, width: w, height: footer), ctx)
    }!
    let got = stitcher.image()!
    T.equal(got.height, header + 900 + band + footer, "height:")
    T.expect(bytes(got) == bytes(want), "stitched pixels differ from the real page")
}
T.test("repetitive lines (logs, tables) stitch at the true offset") {
    // 200 identical "lines" except a small unique mark on the left — like numbered log lines.
    let (w, h, lineHeight) = (500, 400, 20)
    let doc = Renderer.draw(size: CGSize(width: w, height: 200 * lineHeight)) { ctx in
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: 200 * lineHeight))
        for line in 0..<200 {
            let y = line * lineHeight + 6
            for bit in 0..<8 where (line >> bit) & 1 == 1 {   // the "line number": 8 small blocks
                ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 8 + bit * 5, y: y, width: 4, height: 8))
            }
            ctx.setFillColor(CGColor(gray: 0.3, alpha: 1)); ctx.fill(CGRect(x: 60, y: y, width: 400, height: 8))  // same text every line
        }
    }!
    var st = Stitcher(width: w, height: h)
    var offset = 0
    st.add(viewport(doc, offset: 0, width: w, height: h, header: 0, footer: 0))
    for step in [170, 170, 170, 170, 170, 170] {
        offset += step
        T.equal(st.add(viewport(doc, offset: offset, width: w, height: h, header: 0, footer: 0)), .appended(step), "at \(offset):")
    }
    let got = st.image()!
    T.expect(bytes(got) == bytes(doc.cropping(to: CGRect(x: 0, y: 0, width: w, height: offset + h))!), "stitched pixels differ")
}
T.test("a floating button over the content doesn't break matching") {
    let (w, h) = (300, 400)
    let full = page(width: w, height: 3000, seed: 3)
    func frame(_ offset: Int) -> CGImage {
        Renderer.draw(size: CGSize(width: w, height: h)) { ctx in
            Renderer.drawImage(viewport(full, offset: offset, width: w, height: h, header: 0, footer: 0), in: CGRect(x: 0, y: 0, width: w, height: h), ctx)
            ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.3, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: w - 60, y: h - 70, width: 44, height: 44))
        }!
    }
    var st = Stitcher(width: w, height: h)
    st.add(frame(100))
    T.equal(st.add(frame(250)), .appended(150))
    T.equal(st.add(frame(390)), .appended(140))
}
T.test("scrolling back up or jumping too far is skipped, not glued on") {
    let (w, h) = (300, 400)
    let full = page(width: w, height: 3000, seed: 3)
    var stitcher = Stitcher(width: w, height: h)
    stitcher.add(viewport(full, offset: 0, width: w, height: h, header: 0, footer: 0))
    T.equal(stitcher.add(viewport(full, offset: 100, width: w, height: h, header: 0, footer: 0)), .appended(100))
    T.equal(stitcher.add(viewport(full, offset: 40, width: w, height: h, header: 0, footer: 0)), .lost, "up:")
    T.equal(stitcher.add(viewport(full, offset: 1500, width: w, height: h, header: 0, footer: 0)), .lost, "too far:")
    T.equal(stitcher.add(viewport(full, offset: 250, width: w, height: h, header: 0, footer: 0)), .appended(150), "recovers:")
    T.equal(stitcher.totalHeight, 650)
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

print("GIFEncoder")
T.test("encodes a looping GIF with every frame") {
    let frames = (0..<3).map { i in Renderer.draw(size: CGSize(width: 40, height: 30)) { ctx in
        ctx.setFillColor(CGColor(gray: CGFloat(i) / 3, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    }! }
    guard let data = GIFEncoder.encode(frames, delay: 0.1), let source = CGImageSourceCreateWithData(data as CFData, nil) else {
        return T.expect(false, "no GIF")
    }
    T.equal(CGImageSourceGetCount(source), 3)
    let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
    let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    T.equal(gif?[kCGImagePropertyGIFLoopCount] as? Int, 0, "loops forever:")
    T.expect(GIFEncoder.encode([], delay: 0.1) == nil, "no frames, no GIF")
}

T.test("pieces of one line are joined left to right") {
    let pieces = [
        TextRecognizer.Line(text: "value", frame: CGRect(x: 200, y: 10, width: 80, height: 20)),
        TextRecognizer.Line(text: "Label", frame: CGRect(x: 10, y: 12, width: 60, height: 18)),
        TextRecognizer.Line(text: "Next line", frame: CGRect(x: 10, y: 50, width: 90, height: 20)),
    ]
    T.equal(TextRecognizer.joinRows(pieces), "Label value\nNext line")
}
T.test("tall images are read in overlapping tiles") {
    T.equal(TextRecognizer.tiles(width: 800, height: 900).count, 1)
    let tiles = TextRecognizer.tiles(width: 800, height: 5000)
    T.equal(tiles.first?.minY, 0)
    T.equal(tiles.last?.maxY, 5000, "reaches the bottom:")
    T.expect(zip(tiles, tiles.dropFirst()).allSatisfy { $0.maxY - $1.minY == 80 }, "80 px overlaps")
}

print("FileNaming")
T.test("dated name and unique suffix") {
    let date = ISO8601DateFormatter().date(from: "2026-09-24T13:04:12Z")!
    T.expect(FileNaming.name(for: date).hasPrefix("Glint 2026-09-24 at "), FileNaming.name(for: date))
    T.expect(FileNaming.name(for: date, prefix: "").hasPrefix("2026-09-24 at "), "empty prefix")
    T.expect(FileNaming.name(for: date, prefix: "Bug: login/2").hasPrefix("Bug- login-2 2026"), "unsafe characters replaced")
    let dir = URL(fileURLWithPath: "/tmp/x")
    let taken: Set<String> = ["/tmp/x/a.png", "/tmp/x/a 2.png"]
    T.equal(FileNaming.unique("a.png", in: dir) { taken.contains($0.path) }.lastPathComponent, "a 3.png")
}

T.finish()
