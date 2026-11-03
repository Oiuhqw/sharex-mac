import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Kinds of mark the editor can place. All geometry is in frozen-frame points, y-down.
public enum ShapeKind: String, Codable, CaseIterable, Sendable {
    case rectangle, ellipse, line, arrow, highlighter, blur, pixelate, spotlight, pen, text, step

    /// ShareX-style single-key shortcut in the editor.
    public var key: Character {
        switch self {
        case .rectangle: "r"; case .ellipse: "e"; case .line: "l"; case .arrow: "a"
        case .highlighter: "h"; case .blur: "b"; case .pixelate: "p"; case .spotlight: "s"
        case .pen: "f"; case .text: "t"; case .step: "i"
        }
    }

    /// Effects modify the pixels under them instead of drawing on top.
    public var isEffect: Bool { self == .blur || self == .pixelate || self == .spotlight }
    /// Shapes defined by two points that can be dragged, as opposed to a rect.
    public var isSegment: Bool { self == .line || self == .arrow }
}

/// The editor's active tool.
public enum Tool: Hashable, Sendable {
    case select, crop, shape(ShapeKind)

    public static func forKey(_ c: Character) -> Tool? {
        switch c {
        case "v": .select
        case "c": .crop
        default: ShapeKind.allCases.first { $0.key == c }.map(Tool.shape)
        }
    }
}

public struct ShapeStyle: Codable, Hashable, Sendable {
    public var color: RGBA
    public var width: Double
    public var opacity: Double
    public var filled: Bool
    public var fontSize: Double
    /// Blur radius / pixel block size / spotlight dim amount (0-1 scaled by 100).
    public var strength: Double

    public init(color: RGBA = .red, width: Double = 4, opacity: Double = 1, filled: Bool = false, fontSize: Double = 24, strength: Double = 12) {
        (self.color, self.width, self.opacity, self.filled, self.fontSize, self.strength) = (color, width, opacity, filled, fontSize, strength)
    }

    /// Missing keys keep their defaults, like CaptureOptions, so a style field added later keeps saved styles.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        let def = ShapeStyle()
        self.init(color: v(.color, def.color), width: v(.width, def.width), opacity: v(.opacity, def.opacity),
                  filled: v(.filled, def.filled), fontSize: v(.fontSize, def.fontSize), strength: v(.strength, def.strength))
    }

    /// Clamped to the ranges the toolbar offers (see ToolbarView), so stored styles can't produce
    /// negative radii, invisible marks or runaway blur sizes.
    public func sanitized() -> ShapeStyle {
        func c(_ x: Double, _ lo: Double, _ hi: Double, _ def: Double) -> Double { x.isFinite ? min(max(lo, x), hi) : def }
        return ShapeStyle(color: color.sanitized(), width: c(width, 0, 40, 4), opacity: c(opacity, 0.1, 1, 1), filled: filled,
                          fontSize: c(fontSize, 8, 96, 24), strength: c(strength, 0, 100, 12))
    }

    /// ShareX-like defaults per tool.
    public static func defaults(for k: ShapeKind) -> ShapeStyle {
        switch k {
        case .highlighter: ShapeStyle(color: .yellow, width: 0, opacity: 0.4, filled: true)
        case .blur: ShapeStyle(strength: 12)
        case .pixelate: ShapeStyle(strength: 10)
        case .spotlight: ShapeStyle(color: .black, strength: 60)
        case .text: ShapeStyle(color: .red, width: 0, fontSize: 24)
        case .step: ShapeStyle(color: .red, width: 0, filled: true, fontSize: 18)
        default: ShapeStyle()
        }
    }
}

public struct Annotation: Identifiable, Codable, Equatable, Sendable {
    public var id: Int
    public var kind: ShapeKind
    public var style: ShapeStyle
    /// Drag start / end. Rect kinds use the normalized rect; line/arrow use them directly;
    /// step uses `start` as its centre; text uses `start` as its top-left.
    public var start: CGPoint
    public var end: CGPoint
    public var points: [CGPoint] = []
    public var text: String = ""

    public init(id: Int, kind: ShapeKind, style: ShapeStyle, start: CGPoint, end: CGPoint) {
        (self.id, self.kind, self.style, self.start, self.end) = (id, kind, style, start, end)
        if kind == .pen { points = [start] }
    }

    public var rect: CGRect { Geometry.rect(from: start, to: end) }

    public var stepRadius: CGFloat { CGFloat(style.fontSize) * 0.9 }

    /// Approximate text box: real metrics come from the renderer, this is for hit testing.
    public var textSize: CGSize {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let longest = lines.map(\.count).max() ?? 0
        return CGSize(width: max(1, CGFloat(longest)) * CGFloat(style.fontSize) * 0.6 + 8,
                      height: CGFloat(max(1, lines.count)) * CGFloat(style.fontSize) * 1.25 + 4)
    }

    /// The box the selection chrome draws.
    public var bounds: CGRect {
        switch kind {
        case .pen: Geometry.bounds(of: points)
        case .step:
            CGRect(x: start.x - stepRadius, y: start.y - stepRadius, width: 2 * stepRadius, height: 2 * stepRadius)
        case .text: CGRect(origin: start, size: textSize)
        default: rect
        }
    }

    /// Whether a click at `p` should select this annotation.
    public func hit(_ p: CGPoint, tolerance t: CGFloat = 6) -> Bool {
        let slop = t + CGFloat(style.width) / 2
        switch kind {
        case .line:
            return Geometry.distance(p, toSegment: start, end) <= slop
        case .arrow:
            if Geometry.distance(p, toSegment: start, end) <= slop { return true }
            // The renderer paints a filled triangular head. Its wings extend beyond the shaft's
            // hit tolerance for wider arrows, so include its interior and all three edges.
            let (left, right) = Geometry.arrowHead(tail: start, tip: end, length: max(10, CGFloat(style.width) * 4))
            func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
                (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            }
            let a = cross(end, left, p), b = cross(left, right, p), c = cross(right, end, p)
            let inside = abs(cross(end, left, right)) > CGFloat.ulpOfOne
                && ((a >= 0 && b >= 0 && c >= 0) || (a <= 0 && b <= 0 && c <= 0))
            return inside || Geometry.distance(p, toSegment: end, left) <= t
                || Geometry.distance(p, toSegment: left, right) <= t
                || Geometry.distance(p, toSegment: right, end) <= t
        case .pen:
            if points.count == 1 { return hypot(p.x - points[0].x, p.y - points[0].y) <= slop }
            return zip(points, points.dropFirst()).contains { Geometry.distance(p, toSegment: $0, $1) <= slop }
        case .ellipse:
            // Match the painted ellipse, not its rectangular bounds: diagonal edges are selectable
            // and empty corners remain clickable through to marks underneath.
            func contains(_ r: CGRect) -> Bool {
                guard r.width > 0, r.height > 0 else { return false }
                let x = (p.x - r.midX) / (r.width / 2)
                let y = (p.y - r.midY) / (r.height / 2)
                return x * x + y * y <= 1
            }
            let tolerance = style.filled ? t : slop
            guard contains(rect.insetBy(dx: -tolerance, dy: -tolerance)) else { return false }
            return style.filled || !contains(rect.insetBy(dx: tolerance, dy: tolerance))
        case .rectangle where !style.filled:
            // Outline only: the interior stays clickable through to what lies beneath.
            let outer = rect.insetBy(dx: -slop, dy: -slop), inner = rect.insetBy(dx: slop, dy: slop)
            return outer.contains(p) && !(inner.width > 0 && inner.height > 0 && inner.contains(p))
        default:
            return bounds.insetBy(dx: -t, dy: -t).contains(p)
        }
    }

    public func moved(by d: Offset) -> Annotation {
        var a = self
        a.start.x += d.dx; a.start.y += d.dy; a.end.x += d.dx; a.end.y += d.dy
        a.points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
        return a
    }

    /// Resizes via a handle on `bounds`. Pen strokes scale their points; segments move the nearer endpoint.
    public func resized(_ h: Handle, by d: Offset) -> Annotation {
        var a = self
        switch kind {
        case .line, .arrow:
            let p = h.point(on: bounds)
            if hypot(p.x - start.x, p.y - start.y) <= hypot(p.x - end.x, p.y - end.y) {
                a.start.x += d.dx; a.start.y += d.dy
            } else { a.end.x += d.dx; a.end.y += d.dy }
        case .pen:
            let old = bounds, new = h.resize(old, by: d)
            let sx = old.width == 0 ? 1 : new.width / old.width, sy = old.height == 0 ? 1 : new.height / old.height
            a.points = points.map { CGPoint(x: new.minX + ($0.x - old.minX) * sx, y: new.minY + ($0.y - old.minY) * sy) }
        case .step, .text:
            return moved(by: d)   // fixed-size marks: a handle drag just moves them
        default:
            let r = h.resize(rect, by: d)
            a.start = r.origin; a.end = CGPoint(x: r.maxX, y: r.maxY)
        }
        return a
    }

    /// Marks smaller than this are treated as accidental clicks and discarded.
    public var isDegenerate: Bool {
        switch kind {
        case .text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .step: false
        case .pen: points.count < 2
        case .line, .arrow: hypot(end.x - start.x, end.y - start.y) < 3
        default: rect.width < 3 || rect.height < 3
        }
    }
}

