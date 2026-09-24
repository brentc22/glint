import AppKit
import GlintCore

enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, rectangle, ellipse, line, pen, highlight, text, counter, pixelate, redact, crop
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .pen: "scribble"
        case .highlight: "highlighter"
        case .text: "textformat"
        case .counter: "1.circle"
        case .pixelate: "checkerboard.rectangle"
        case .redact: "rectangle.fill"
        case .crop: "crop"
        }
    }

    /// Single-letter shortcut, shown in the tooltip.
    var key: Character {
        switch self {
        case .select: "v"; case .arrow: "a"; case .rectangle: "r"; case .ellipse: "o"; case .line: "l"
        case .pen: "d"; case .highlight: "h"; case .text: "t"; case .counter: "n"; case .pixelate: "p"
        case .redact: "b"; case .crop: "c"
        }
    }

    var title: String {
        switch self {
        case .select: "Select"; case .arrow: "Arrow"; case .rectangle: "Rectangle"; case .ellipse: "Ellipse"
        case .line: "Line"; case .pen: "Pen"; case .highlight: "Highlight"; case .text: "Text"
        case .counter: "Step counter"; case .pixelate: "Pixelate"; case .redact: "Black out"; case .crop: "Crop"
        }
    }
}

enum StrokeSize: CGFloat, CaseIterable, Identifiable {
    case small = 3, medium = 6, large = 10
    var id: CGFloat { rawValue }
}

@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var document: Document
    @Published var tool: Tool = .arrow { didSet { if tool != .select { selectedID = nil } } }
    @Published var color: RGBA = .red { didSet { restyleSelection() } }
    @Published var size: StrokeSize = .medium { didSet { restyleSelection() } }
    @Published var selectedID: Annotation.ID?
    @Published private(set) var isRedacting = false
    @Published var backdrop: Int? { didSet { document.apply { $0.backdrop = backdrop.map { Backdrop.presets[$0] } } } }

    let capture: Capture

    init(capture: Capture) {
        self.capture = capture
        document = Document(image: capture.image, scale: capture.scale)
    }

    /// Stroke width in image pixels — same visual weight on Retina and non-Retina shots.
    var lineWidth: CGFloat { size.rawValue * document.scale }
    var textSize: CGFloat { (14 + size.rawValue * 2.5) * document.scale }

    func mutate(_ change: (inout Document) -> Void) { change(&document) }

    func add(_ kind: Annotation.Kind) {
        let annotation = Annotation(kind, color: kind.isRedaction ? .black : color, lineWidth: lineWidth)
        mutate { $0.add(annotation) }
        selectedID = annotation.id
    }

    func undo() { mutate { $0.undo() }; selectedID = nil }
    func redo() { mutate { $0.redo() }; selectedID = nil }

    func deleteSelection() {
        guard let id = selectedID else { return }
        mutate { $0.remove(id: id) }
        selectedID = nil
    }

    func nudge(_ d: CGSize) {
        guard let id = selectedID, let a = document.annotations.first(where: { $0.id == id }) else { return }
        mutate { $0.replace(a.offset(by: d)) }
    }

    private func restyleSelection() {
        guard let id = selectedID, var a = document.annotations.first(where: { $0.id == id }), !a.kind.isRedaction else { return }
        a.color = color
        a.lineWidth = lineWidth
        if case let .text(s, o, _) = a.kind { a.kind = .text(s, at: o, size: textSize) }
        mutate { $0.replace(a) }
    }

    /// Finds emails, phone numbers, IBANs, card numbers, API keys, tokens and IPs with
    /// on-device OCR and pixelates them — as ordinary annotations, so each can be moved
    /// or deleted if it caught too much.
    func autoRedact() async -> Int {
        isRedacting = true
        defer { isRedacting = false }
        let regions = await TextRecognizer.sensitiveRegions(in: document.image)
        let existing = document.annotations.compactMap { if case let .pixelate(r) = $0.kind { r } else { nil } }
        let new = regions.filter { !existing.contains($0) }
        guard !new.isEmpty else { return 0 }
        mutate { doc in doc.apply { state in state.annotations += new.map { Annotation(.pixelate($0)) } } }
        return new.count
    }

    func recognizedText() async -> String { await TextRecognizer.text(in: document.render() ?? document.image) }

    func export() -> CGImage { document.render() ?? document.image }
}

extension Annotation.Kind {
    var isRedaction: Bool {
        switch self { case .pixelate, .filledRectangle: true; default: false }
    }
}
