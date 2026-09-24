import AppKit
import Combine
import GlintCore

/// The drawing surface. Keeps the screenshot fitted and centered, converts between view
/// points and image pixels, and draws through `Renderer` — the same code as the export.
@MainActor
final class CanvasView: NSView, NSTextFieldDelegate {
    struct Commands {
        var copy: () -> Void = {}
        var save: () -> Void = {}
        var close: () -> Void = {}
        var done: () -> Void = {}
    }

    private enum Drag {
        case shape(start: CGPoint, current: CGPoint)
        case pen([CGPoint])
        case move(Annotation, start: CGPoint, current: CGPoint)
    }

    private let model: EditorModel
    var commands = Commands()
    private var drag: Drag?
    private var textField: NSTextField?
    private var textOrigin: CGPoint?
    private var observation: AnyCancellable?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        // Toolbar changes (tool, selection, backdrop) arrive here; objectWillChange fires
        // before the value changes, so redraw on the next turn of the run loop.
        observation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.needsDisplay = true
                self.window?.invalidateCursorRects(for: self)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    private var doc: Document { model.document }
    private var padding: CGFloat { doc.state.backdrop.map { $0.padding * max(1, CGFloat(doc.image.width) / 1600) } ?? 0 }

    /// Image pixels → view points: uniform scale plus offset, centered, never above 100 %.
    private var fit: (scale: CGFloat, origin: CGPoint) {
        let w = CGFloat(doc.image.width) + padding * 2, h = CGFloat(doc.image.height) + padding * 2
        let area = bounds.insetBy(dx: 32, dy: 32)
        let scale = min(area.width / w, area.height / h, 1 / doc.scale)
        let origin = CGPoint(x: bounds.midX - CGFloat(doc.image.width) * scale / 2,
                             y: bounds.midY - CGFloat(doc.image.height) * scale / 2)
        return (scale, origin)
    }

    private func toImage(_ p: CGPoint) -> CGPoint {
        let f = fit
        return CGPoint(x: (p.x - f.origin.x) / f.scale, y: (p.y - f.origin.y) / f.scale)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let f = fit
        return CGPoint(x: p.x * f.scale + f.origin.x, y: p.y * f.scale + f.origin.y)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()

        let f = fit
        ctx.saveGState()
        ctx.translateBy(x: f.origin.x, y: f.origin.y)
        ctx.scaleBy(x: f.scale, y: f.scale)
        let imageRect = doc.imageRect

        if let backdrop = doc.state.backdrop {
            let outer = imageRect.insetBy(dx: -padding, dy: -padding)
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [backdrop.from.cgColor, backdrop.to.cgColor] as CFArray, locations: [0, 1])!
            ctx.saveGState()
            ctx.addRect(outer)
            ctx.clip()
            ctx.drawLinearGradient(gradient, start: outer.origin, end: CGPoint(x: outer.maxX, y: outer.maxY), options: [])
            ctx.restoreGState()
            ctx.addPath(CGPath(roundedRect: imageRect, cornerWidth: backdrop.cornerRadius, cornerHeight: backdrop.cornerRadius, transform: nil))
            ctx.clip()
        } else {
            ctx.setShadow(offset: CGSize(width: 0, height: 6 / f.scale), blur: 24 / f.scale, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(imageRect)
            ctx.setShadow(offset: .zero, blur: 0)
        }

        Renderer.drawImage(doc.image, in: imageRect, ctx)
        Renderer.draw(visibleAnnotations, over: doc.image, in: ctx)
        ctx.resetClip()

        if let crop = cropRect {
            ctx.addRect(imageRect)
            ctx.addRect(crop)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5 / f.scale)
            ctx.stroke(crop)
        }

        if let id = model.selectedID, let selected = visibleAnnotations.first(where: { $0.id == id }) {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5 / f.scale)
            ctx.setLineDash(phase: 0, lengths: [5 / f.scale, 4 / f.scale])
            ctx.stroke(selected.bounds.insetBy(dx: -4 / f.scale, dy: -4 / f.scale))
        }
        ctx.restoreGState()
    }

    /// Committed annotations, with the one being dragged shown at its new spot and the
    /// shape being drawn shown as a preview.
    private var visibleAnnotations: [Annotation] {
        var list = doc.annotations
        switch drag {
        case let .move(original, start, current):
            if let i = list.firstIndex(where: { $0.id == original.id }) {
                list[i] = original.offset(by: CGSize(width: current.x - start.x, height: current.y - start.y))
            }
        case let .shape(start, current):
            if let kind = shape(from: start, to: current) {
                list.append(Annotation(kind, color: kind.isRedaction ? .black : model.color, lineWidth: model.lineWidth))
            }
        case let .pen(points):
            list.append(Annotation(.freehand(points), color: model.color, lineWidth: model.lineWidth))
        case nil: break
        }
        return list
    }

    private var cropRect: CGRect? {
        if model.tool == .crop, case let .shape(a, b) = drag { return CGRect(from: a, to: b).intersection(doc.imageRect) }
        return doc.state.crop
    }

    /// Shift snaps lines to 45° and boxes to squares.
    private func shape(from a: CGPoint, to raw: CGPoint) -> Annotation.Kind? {
        let shift = NSEvent.modifierFlags.contains(.shift)
        var b = raw
        switch model.tool {
        case .arrow, .line:
            if shift {
                let angle = (atan2(raw.y - a.y, raw.x - a.x) / (.pi / 4)).rounded() * (.pi / 4)
                let length = hypot(raw.x - a.x, raw.y - a.y)
                b = CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
            }
            return model.tool == .arrow ? .arrow(from: a, to: b) : .line(from: a, to: b)
        case .rectangle, .ellipse, .highlight, .pixelate, .redact:
            if shift {
                let side = max(abs(raw.x - a.x), abs(raw.y - a.y))
                b = CGPoint(x: a.x + (raw.x < a.x ? -side : side), y: a.y + (raw.y < a.y ? -side : side))
            }
            let r = CGRect(from: a, to: b)
            switch model.tool {
            case .rectangle: return .rectangle(r)
            case .ellipse: return .ellipse(r)
            case .highlight: return .highlight(r)
            case .pixelate: return .pixelate(r)
            default: return .filledRectangle(r)
            }
        default:
            return nil
        }
    }

    // MARK: Mouse

    override func resetCursorRects() {
        switch model.tool {
        case .select: addCursorRect(bounds, cursor: .arrow)
        case .text: addCursorRect(bounds, cursor: .iBeam)
        default: addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        commitText()
        window?.makeFirstResponder(self)
        let p = toImage(convert(event.locationInWindow, from: nil))
        switch model.tool {
        case .select:
            if let hit = doc.hit(p) {
                model.selectedID = hit.id
                drag = .move(hit, start: p, current: p)
            } else {
                model.selectedID = nil
            }
        case .text:
            beginText(at: p)
        case .counter:
            model.add(.counter(doc.nextCounter, at: p))
        case .pen:
            drag = .pen([p])
        default:
            drag = .shape(start: p, current: p)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = toImage(convert(event.locationInWindow, from: nil))
        switch drag {
        case let .shape(start, _): drag = .shape(start: start, current: p)
        case let .pen(points): drag = .pen(points + [p])
        case let .move(a, start, _): drag = .move(a, start: start, current: p)
        case nil: return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; needsDisplay = true }
        switch drag {
        case let .shape(a, b):
            guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
            if model.tool == .crop {
                let crop = CGRect(from: a, to: b).intersection(doc.imageRect)
                model.mutate { $0.apply { $0.crop = crop.isEmpty ? nil : crop } }
            } else if let kind = shape(from: a, to: b) {
                model.add(kind)
            }
        case let .pen(points) where points.count > 2:
            model.add(.freehand(points))
        case let .move(original, start, current) where start != current:
            model.mutate { $0.replace(original.offset(by: CGSize(width: current.x - start.x, height: current.y - start.y))) }
        default:
            break
        }
    }

    // MARK: Text

    private func beginText(at p: CGPoint) {
        let field = NSTextField(string: "")
        let viewSize = model.textSize * fit.scale
        field.font = .systemFont(ofSize: viewSize, weight: .bold)
        field.textColor = NSColor(cgColor: model.color.cgColor)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Type…"
        field.delegate = self
        let origin = toView(p)
        field.frame = CGRect(x: origin.x - 2, y: origin.y - viewSize * 0.12, width: max(240, bounds.maxX - origin.x - 20), height: viewSize * 1.4)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        textOrigin = p
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    private func commitText() {
        guard let field = textField, let origin = textOrigin else { return }
        textField = nil
        textOrigin = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        if !text.isEmpty { model.add(.text(text, at: origin, size: model.textSize)) }
        window?.makeFirstResponder(self)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags.contains(.command) {
            switch key {
            case "z": flags.contains(.shift) ? model.redo() : model.undo()
            case "c": commands.copy()
            case "s": commands.save()
            case "w": commands.close()
            case "\r": commands.done()
            default: super.keyDown(with: event)
            }
            return
        }
        let step: CGFloat = (flags.contains(.shift) ? 10 : 1) * doc.scale
        switch Int(event.keyCode) {
        case 51, 117: model.deleteSelection()
        case 53: if model.selectedID != nil { model.selectedID = nil } else { commands.close() }
        case 123: model.nudge(CGSize(width: -step, height: 0))
        case 124: model.nudge(CGSize(width: step, height: 0))
        case 125: model.nudge(CGSize(width: 0, height: step))
        case 126: model.nudge(CGSize(width: 0, height: -step))
        default:
            if let tool = Tool.allCases.first(where: { String($0.key) == key }) {
                model.tool = tool
                window?.invalidateCursorRects(for: self)
            } else {
                super.keyDown(with: event)
            }
        }
        needsDisplay = true
    }
}
