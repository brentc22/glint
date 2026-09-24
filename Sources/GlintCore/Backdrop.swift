import CoreGraphics

/// A gradient frame around the screenshot, with rounded corners and a shadow —
/// the "make it presentable" look for posts, docs and slides.
public struct Backdrop: Equatable, Sendable {
    public var from: RGBA
    public var to: RGBA
    public var padding: CGFloat
    public var cornerRadius: CGFloat

    public init(from: RGBA, to: RGBA, padding: CGFloat = 64, cornerRadius: CGFloat = 12) {
        self.from = from
        self.to = to
        self.padding = padding
        self.cornerRadius = cornerRadius
    }

    public static let presets: [Backdrop] = [
        Backdrop(from: RGBA(0.99, 0.45, 0.42), to: RGBA(0.98, 0.76, 0.35)),  // sunset
        Backdrop(from: RGBA(0.36, 0.42, 0.98), to: RGBA(0.76, 0.40, 0.95)),  // violet
        Backdrop(from: RGBA(0.20, 0.80, 0.70), to: RGBA(0.25, 0.47, 0.95)),  // ocean
        Backdrop(from: RGBA(0.13, 0.15, 0.20), to: RGBA(0.30, 0.34, 0.42)),  // graphite
        Backdrop(from: RGBA(0.95, 0.95, 0.97), to: RGBA(0.86, 0.88, 0.92)),  // paper
    ]
}
