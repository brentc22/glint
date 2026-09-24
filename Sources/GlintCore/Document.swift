import CoreGraphics

/// A screenshot being edited: the captured pixels plus everything drawn on top.
/// Value type with a snapshot-based undo stack, so undo is just "restore the previous value".
public struct Document: Sendable {
    public struct State: Equatable, Sendable {
        public var annotations: [Annotation] = []
        public var crop: CGRect?
        public var backdrop: Backdrop?
    }

    public let image: CGImage
    /// Screen scale the image was captured at (2 on Retina) — sizes stroke widths so a
    /// "medium" arrow looks the same on every display.
    public let scale: CGFloat
    /// A bare window capture: the export gets the drop shadow back (unless a backdrop frames it).
    public let windowShadow: Bool
    public private(set) var state = State()
    private var undoStack: [State] = []
    private var redoStack: [State] = []

    public init(image: CGImage, scale: CGFloat = 2, windowShadow: Bool = false) {
        self.image = image
        self.scale = scale
        self.windowShadow = windowShadow
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var annotations: [Annotation] { state.annotations }
    public var imageRect: CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }

    /// Next number for the counter tool: one past the highest on the canvas.
    public var nextCounter: Int {
        (state.annotations.compactMap { if case let .counter(n, _) = $0.kind { n } else { nil } }.max() ?? 0) + 1
    }

    public mutating func apply(_ change: (inout State) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        undoStack.append(state)
        redoStack.removeAll()
        state = next
    }

    public mutating func add(_ annotation: Annotation) { apply { $0.annotations.append(annotation) } }

    public mutating func remove(id: Annotation.ID) { apply { $0.annotations.removeAll { $0.id == id } } }

    public mutating func replace(_ annotation: Annotation) {
        apply { state in
            if let i = state.annotations.firstIndex(where: { $0.id == annotation.id }) {
                state.annotations[i] = annotation
            }
        }
    }

    public mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = previous
    }

    public mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
    }

    /// Topmost annotation under `point`, so clicking selects what you see on top.
    public func hit(_ point: CGPoint) -> Annotation? {
        state.annotations.last { $0.bounds.insetBy(dx: -6, dy: -6).contains(point) }
    }

    public func render() -> CGImage? {
        Renderer.render(image, annotations: state.annotations, crop: state.crop, backdrop: state.backdrop,
                        windowShadow: windowShadow ? scale : nil)
    }
}
