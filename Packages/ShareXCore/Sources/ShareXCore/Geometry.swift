import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Rect math shared by the overlay and the capture engine.
///
/// Coordinate spaces:
/// - Cocoa global: points, origin bottom-left of the primary screen, y up (NSScreen.frame).
/// - Display top-left: points, origin top-left of one display, y down (ScreenCaptureKit sourceRect).
/// - Image pixels: display top-left scaled by the display's backing scale.
///
/// Point rects are `CGRect` (always display top-left unless a name says Cocoa). Pixel rects are
/// `PixelRect`, a separate integer type, so passing points where pixels are expected does not compile.
public enum Geometry {
    /// The normalized rect spanned by two drag points.
    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Converts a rect in Cocoa global space to top-left points local to `screenFrame`.
    public static func cocoaToDisplayTopLeft(_ r: CGRect, screenFrame s: CGRect) -> CGRect {
        CGRect(x: r.minX - s.minX, y: s.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// Scales a point rect to pixels and snaps outward to whole pixels so a selection never loses an edge.
    public static func pixelRect(_ r: CGRect, scale: CGFloat) -> PixelRect {
        // A tiny epsilon keeps rects that came from whole pixels (p / scale * scale) from growing by one.
        let e: CGFloat = 1e-6
        let x0 = Int((r.minX * scale + e).rounded(.down)), y0 = Int((r.minY * scale + e).rounded(.down))
        let x1 = Int((r.maxX * scale - e).rounded(.up)), y1 = Int((r.maxY * scale - e).rounded(.up))
        return PixelRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    public static func capturePixels(_ r: CGRect, scale: CGFloat, width: Int, height: Int) -> PixelRect? {
        guard scale.isFinite, scale > 0, width > 0, height > 0, width < Int.max / 4, height < Int.max / 4,
              r.origin.x.isFinite, r.origin.y.isFinite, r.width.isFinite, r.height.isFinite,
              r.maxX.isFinite, r.maxY.isFinite else { return nil }
        let clipped = r.intersection(CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale))
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        return pixelRect(clipped, scale: scale).clamped(width: width, height: height)
    }

    /// Clamps `r` inside `bounds`. Returns nil when nothing remains.
    public static func clamp(_ r: CGRect, to bounds: CGRect) -> CGRect? {
        let i = r.intersection(bounds)
        return (i.isNull || i.width < 1 || i.height < 1) ? nil : i
    }

    /// The selection a crop-tool drag from `a` to `b` produces inside `bounds`, or nil when the drag is
    /// smaller than one image pixel. Callers keep the previous crop on nil instead of clearing it.
    public static func cropDrag(from a: CGPoint, to b: CGPoint, in bounds: CGRect, scale: CGFloat = 1) -> CGRect? {
        let r = rect(from: a, to: b).intersection(bounds)
        guard scale.isFinite, scale > 0, !r.isNull, r.width * scale >= 1, r.height * scale >= 1 else { return nil }
        return r
    }

    /// Bounding box of all frames (the virtual desktop).
    public static func union(_ frames: [CGRect]) -> CGRect {
        frames.dropFirst().reduce(frames.first ?? .zero) { $0.union($1) }
    }

    /// Bounding box of a point list.
    public static func bounds(of pts: [CGPoint]) -> CGRect {
        guard let f = pts.first else { return .null }
        var r = CGRect(origin: f, size: .zero)
        for p in pts.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    /// Distance from `p` to segment `a`-`b`.
    public static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        let cx = a.x + t * dx - p.x, cy = a.y + t * dy - p.y
        return (cx * cx + cy * cy).squareRoot()
    }

    /// The two barb end points of an arrow head at `tip`, pointing away from `tail`.
    public static func arrowHead(tail: CGPoint, tip: CGPoint, length: CGFloat, spread: CGFloat = .pi / 7) -> (CGPoint, CGPoint) {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        func barb(_ d: CGFloat) -> CGPoint {
            CGPoint(x: tip.x - length * cos(angle + d), y: tip.y - length * sin(angle + d))
        }
        return (barb(spread), barb(-spread))
    }
}

/// The eight resize handles of a rect, plus the move body.
public enum Handle: CaseIterable, Sendable, Equatable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Handle centre on `r` (y-down: "top" is minY).
    public func point(on r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .top: CGPoint(x: r.midX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// Returns `r` with this handle dragged by `d`, normalized so dragging past the opposite edge flips.
    public func resize(_ r: CGRect, by d: Offset) -> CGRect {
        var x0 = r.minX, y0 = r.minY, x1 = r.maxX, y1 = r.maxY
        switch self {
        case .topLeft: x0 += d.dx; y0 += d.dy
        case .top: y0 += d.dy
        case .topRight: x1 += d.dx; y0 += d.dy
        case .right: x1 += d.dx
        case .bottomRight: x1 += d.dx; y1 += d.dy
        case .bottom: y1 += d.dy
        case .bottomLeft: x0 += d.dx; y1 += d.dy
        case .left: x0 += d.dx
        }
        return Geometry.rect(from: CGPoint(x: x0, y: y0), to: CGPoint(x: x1, y: y1))
    }

    /// The handle within `tolerance` of `p`, if any.
    public static func hit(_ p: CGPoint, on r: CGRect, tolerance: CGFloat) -> Handle? {
        allCases.first { h in
            let c = h.point(on: r)
            return abs(c.x - p.x) <= tolerance && abs(c.y - p.y) <= tolerance
        }
    }
}

/// A drag delta. Own type because CGVector is not in swift-corelibs-foundation.
public struct Offset: Equatable, Sendable {
    public var dx, dy: CGFloat
    public init(dx: CGFloat, dy: CGFloat) { (self.dx, self.dy) = (dx, dy) }
    public init(from a: CGPoint, to b: CGPoint) { (dx, dy) = (b.x - a.x, b.y - a.y) }
}

/// An integer rect in image pixels, y-down. Distinct from point `CGRect`s on purpose.
public struct PixelRect: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var x, y, w, h: Int
    public init(x: Int, y: Int, w: Int, h: Int) { (self.x, self.y, self.w, self.h) = (x, y, w, h) }

    public var maxX: Int { x + w }
    public var maxY: Int { y + h }
    public var isEmpty: Bool { w <= 0 || h <= 0 }
    public var description: String { "\(x),\(y) \(w)x\(h)" }

    public func intersection(_ other: PixelRect) -> PixelRect? {
        let left = max(x, other.x), top = max(y, other.y), right = min(maxX, other.maxX), bottom = min(maxY, other.maxY)
        return right > left && bottom > top ? PixelRect(x: left, y: top, w: right - left, h: bottom - top) : nil
    }

    public func adjusted(dx: Int, dy: Int, resizing: Bool, width: Int, height: Int) -> PixelRect {
        if resizing {
            return PixelRect(x: x, y: y, w: min(max(1, w + dx), width - x), h: min(max(1, h + dy), height - y))
        }
        return PixelRect(x: min(max(0, x + dx), width - w), y: min(max(0, y + dy), height - h), w: w, h: h)
    }

    /// Intersection with an image of `width`×`height`. Nil when nothing remains.
    public func clamped(width: Int, height: Int) -> PixelRect? {
        let x0 = max(0, x), y0 = max(0, y), x1 = min(width, maxX), y1 = min(height, maxY)
        return x1 > x0 && y1 > y0 ? PixelRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0) : nil
    }

    /// Back to display top-left points.
    public func points(scale: CGFloat) -> CGRect {
        CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
    }

    /// For CoreGraphics calls (`CGImage.cropping`, contexts). Pixel space, not points.
    public var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }

    /// The same rect in a y-up image of `height` pixels (CoreImage).
    public func flippedY(height: Int) -> PixelRect { PixelRect(x: x, y: height - maxY, w: w, h: h) }
}

/// Where each display goes when several are stitched into one image (Fullscreen on many displays).
/// Every display sits at its global position; the canvas uses the highest scale so Retina detail survives.
public struct StitchLayout: Equatable, Sendable {
    /// Pixels per point of the canvas.
    public let scale: CGFloat
    public let width: Int, height: Int
    /// Each display's rect on the canvas, in canvas points, y-down, parallel to the input.
    public let placements: [CGRect]

    /// `frames` are Cocoa global frames; `scales` their backing scales. Nil for no displays or an empty desktop.
    public init?(frames: [CGRect], scales: [CGFloat]) {
        guard !frames.isEmpty, frames.count == scales.count else { return nil }
        let u = Geometry.union(frames)
        let s = scales.max() ?? 1
        guard s > 0, s.isFinite, u.width.isFinite, u.height.isFinite else { return nil }
        let w = (u.width * s).rounded(), h = (u.height * s).rounded()
        guard w >= 1, h >= 1, w < 1e6, h < 1e6 else { return nil }
        scale = s; width = Int(w); height = Int(h)
        placements = frames.map { Geometry.cocoaToDisplayTopLeft($0, screenFrame: u) }
    }
}

/// The numbers behind blur and pixelate. The pixels themselves are made by CoreImage in the app;
/// these are the parts that decide how strong the redaction is and where the grid sits.
public enum EffectMath {
    /// Weakest redaction strength in points (security review N1: 2 px left small text readable).
    public static let minStrength: Double = 8

    /// Gaussian sigma in pixels. Three box passes of radius r approximate σ = r; strength is floored at
    /// `minStrength` points so even the weakest setting does not leave small text readable.
    public static func blurSigma(strength: Double, scale: CGFloat) -> Double {
        let sc = Double(scale).isFinite && scale > 0 ? Double(scale) : 1
        let v = max(minStrength, strength) * sc
        return v.isFinite ? max(minStrength, v) : minStrength
    }

    /// Pixelate block size in pixels; floored at `minStrength` points like blur.
    public static func pixelateBlock(strength: Double, scale: CGFloat) -> Double {
        let sc = Double(scale).isFinite && scale > 0 ? Double(scale) : 1
        let v = max(minStrength, strength) * sc
        return v.isFinite ? max(minStrength, v) : minStrength
    }

    /// CIPixellate centre for a region given in y-up pixels. Blocks are laid out from this point, so using
    /// the region's top-left corner makes the first block start exactly at the region's top-left, as in ShareX.
    public static func pixelateCenter(yUp r: PixelRect) -> CGPoint { CGPoint(x: r.x, y: r.maxY) }

    /// Block index ranges a pixelate grid anchored at `origin` with `block` size produces along one axis
    /// for `count` pixels starting at `start`. Used to prove the grid never straddles the region edge.
    public static func blockStarts(origin: Int, start: Int, count: Int, block: Int) -> [Int] {
        guard block > 0, count > 0 else { return [] }
        var out: [Int] = []
        var b = origin + Int((Double(start - origin) / Double(block)).rounded(.down)) * block
        while b < start + count { out.append(max(b, start)); b += block }
        return out
    }
}
