import CoreGraphics
import Foundation

/// sRGB color as plain numbers, so annotations stay `Sendable` and `Codable`.
public struct RGBA: Equatable, Hashable, Sendable, Codable {
    public var r, g, b, a: CGFloat

    public init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    public static let red = RGBA(1, 0.23, 0.19)
    public static let orange = RGBA(1, 0.62, 0.04)
    public static let yellow = RGBA(1, 0.84, 0.04)
    public static let green = RGBA(0.20, 0.78, 0.35)
    public static let blue = RGBA(0.04, 0.52, 1)
    public static let purple = RGBA(0.69, 0.32, 0.87)
    public static let black = RGBA(0.1, 0.1, 0.1)
    public static let white = RGBA(1, 1, 1)
    public static let palette: [RGBA] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]
}

/// One mark on a screenshot. Geometry is in image pixels, origin top-left — the
/// coordinate space of the screenshot itself, independent of zoom or window size.
public struct Annotation: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case arrow(from: CGPoint, to: CGPoint)
        case line(from: CGPoint, to: CGPoint)
        case rectangle(CGRect)
        case filledRectangle(CGRect)
        case ellipse(CGRect)
        case highlight(CGRect)
        case pixelate(CGRect)
        case freehand([CGPoint])
        case text(String, at: CGPoint, size: CGFloat)
        case counter(Int, at: CGPoint)
    }

    public let id: UUID
    public var kind: Kind
    public var color: RGBA
    public var lineWidth: CGFloat

    public init(id: UUID = UUID(), _ kind: Kind, color: RGBA = .red, lineWidth: CGFloat = 6) {
        self.id = id
        self.kind = kind
        self.color = color
        self.lineWidth = lineWidth
    }

    /// Area the annotation covers, for hit-testing and selection outlines.
    public var bounds: CGRect {
        switch kind {
        case let .arrow(a, b), let .line(a, b):
            return CGRect(from: a, to: b).insetBy(dx: -lineWidth * 2, dy: -lineWidth * 2)
        case let .rectangle(r), let .filledRectangle(r), let .ellipse(r), let .highlight(r), let .pixelate(r):
            return r.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case let .freehand(points):
            return points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
                .insetBy(dx: -lineWidth, dy: -lineWidth)
        case let .text(string, origin, size):
            let width = CGFloat(string.count) * size * 0.6
            return CGRect(x: origin.x, y: origin.y, width: max(width, size), height: size * 1.3)
        case let .counter(_, center):
            let r = Self.counterRadius(lineWidth)
            return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        }
    }

    public static func counterRadius(_ lineWidth: CGFloat) -> CGFloat { 10 + lineWidth * 2.5 }

    /// The same annotation shifted by `delta` — used when dragging a selection.
    public func offset(by d: CGSize) -> Annotation {
        func p(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x + d.width, y: q.y + d.height) }
        func r(_ q: CGRect) -> CGRect { q.offsetBy(dx: d.width, dy: d.height) }
        var copy = self
        switch kind {
        case let .arrow(a, b): copy.kind = .arrow(from: p(a), to: p(b))
        case let .line(a, b): copy.kind = .line(from: p(a), to: p(b))
        case let .rectangle(q): copy.kind = .rectangle(r(q))
        case let .filledRectangle(q): copy.kind = .filledRectangle(r(q))
        case let .ellipse(q): copy.kind = .ellipse(r(q))
        case let .highlight(q): copy.kind = .highlight(r(q))
        case let .pixelate(q): copy.kind = .pixelate(r(q))
        case let .freehand(points): copy.kind = .freehand(points.map(p))
        case let .text(s, o, size): copy.kind = .text(s, at: p(o), size: size)
        case let .counter(n, c): copy.kind = .counter(n, at: p(c))
        }
        return copy
    }
}

extension CGRect {
    /// The rectangle spanned by two corners, in any order.
    public init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
