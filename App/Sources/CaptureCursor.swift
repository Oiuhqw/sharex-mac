import AppKit

@MainActor
enum CaptureCursor {
    /// A small, symmetric target. The open centre leaves the selected pixel visible.
    static let crosshair: NSCursor = {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let path = NSBezierPath()
            let centre: CGFloat = 12
            for direction in [CGFloat(-1), CGFloat(1)] {
                let near = centre + 3 * direction, far = centre + 9 * direction
                path.move(to: NSPoint(x: near, y: centre)); path.line(to: NSPoint(x: far, y: centre))
                path.move(to: NSPoint(x: centre, y: near)); path.line(to: NSPoint(x: centre, y: far))
            }
            path.lineCapStyle = .round
            NSColor.black.setStroke(); path.lineWidth = 3; path.stroke()
            NSColor.white.setStroke(); path.lineWidth = 1; path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }()
}
