import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Frozen display geometry. Raster allocation is a separate, crop-specific decision.
public struct DesktopLayout: Equatable, Sendable {
    public struct Display: Codable, Equatable, Sendable {
        public let id: UInt32
        public let frame: CGRect
        public let scale: CGFloat
        public init(id: UInt32, frame: CGRect, scale: CGFloat) {
            self.id = id; self.frame = frame; self.scale = scale
        }
    }
    public let displays: [Display]
    public let cocoaBounds: CGRect
    public var bounds: CGRect { CGRect(origin: .zero, size: cocoaBounds.size) }

    public init?(displays: [Display]) {
        guard !displays.isEmpty, Set(displays.map(\.id)).count == displays.count,
              displays.allSatisfy({ d in
                  [d.frame.minX, d.frame.minY, d.frame.maxX, d.frame.maxY, d.scale].allSatisfy { $0.isFinite && abs($0) < 1_000_000 }
                      && d.frame.width > 0 && d.frame.height > 0 && d.scale > 0 && d.scale <= 16
              }) else { return nil }
        self.displays = displays
        cocoaBounds = Geometry.union(displays.map(\.frame))
    }

    public func point(cocoa p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - cocoaBounds.minX, y: cocoaBounds.maxY - p.y)
    }
    public func placement(_ display: Display) -> CGRect {
        Geometry.cocoaToDisplayTopLeft(display.frame, screenFrame: cocoaBounds)
    }
    public func participants(in crop: CGRect) -> [Display] {
        displays.filter { let r = placement($0).intersection(crop); return !r.isNull && r.width > 0 && r.height > 0 }
    }
    public func scale(for crop: CGRect) -> CGFloat? { participants(in: crop).map(\.scale).max() }
    public func selection(_ rect: CGRect) -> CGRect? {
        guard [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite) else { return nil }
        let r = rect.intersection(bounds)
        guard !r.isNull, r.width > 0, r.height > 0, scale(for: r) != nil else { return nil }
        return r
    }
}
