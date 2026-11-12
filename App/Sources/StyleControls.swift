import AppKit
import ShareXCore

@MainActor
final class TrackingSlider: NSSlider {
    var beginTracking: (() -> Void)?
    var endTracking: (() -> Void)?
    #if SHAREX_E2E
    private(set) var e2eCompletedGestures = 0
    #endif

    override func mouseDown(with event: NSEvent) {
        beginTracking?()
        defer {
            endTracking?()
            #if SHAREX_E2E
            e2eCompletedGestures += 1
            #endif
        }
        super.mouseDown(with: event)
    }
}

@MainActor
final class ColorSwatch: NSButton {
    let color: RGBA

    init(name: String, color: RGBA, target: AnyObject?, action: Selector) {
        self.color = color
        super.init(frame: .zero)
        title = name; self.target = target; self.action = action
        setButtonType(.pushOnPushOff); isBordered = false
        toolTip = name; setAccessibilityLabel(name)
        widthAnchor.constraint(equalToConstant: 36).isActive = true
        heightAnchor.constraint(equalToConstant: 36).isActive = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("unused") }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 6, dy: 6))
        (NSColor(cgColor: Imaging.cgColor(color)) ?? .red).withAlphaComponent(isEnabled ? 1 : 0.3).setFill()
        circle.fill()
        NSColor.separatorColor.setStroke(); circle.lineWidth = 1; circle.stroke()
        if state == .on {
            NSColor.controlAccentColor.setStroke()
            let rim = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)); rim.lineWidth = 2; rim.stroke()
            let check = NSBezierPath()
            check.move(to: CGPoint(x: 13, y: 18)); check.line(to: CGPoint(x: 17, y: 14)); check.line(to: CGPoint(x: 24, y: 23))
            (color == .white || color == .yellow ? NSColor.black : NSColor.white).setStroke()
            check.lineWidth = 2; check.lineCapStyle = .round; check.lineJoinStyle = .round; check.stroke()
        }
    }
}

@MainActor
final class StylePreviewView: NSView {
    private let renderer: Renderer?
    private var annotation: Annotation?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        if let context = Imaging.context(width: 304, height: 112, flipped: true) {
            for y in stride(from: 0, to: 112, by: 8) {
                for x in stride(from: 0, to: 304, by: 8) {
                    let shade = (x / 8 + y / 8) % 2 == 0 ? 0.92 : 0.76
                    context.setFillColor(CGColor(gray: shade, alpha: 1))
                    context.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
            renderer = context.makeImage().map { Renderer(frame: $0, scale: 1) }
        } else { renderer = nil }
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 6; layer?.masksToBounds = true
        setAccessibilityElement(true); setAccessibilityLabel("Current style preview")
        widthAnchor.constraint(equalToConstant: 304).isActive = true
        heightAnchor.constraint(equalToConstant: 112).isActive = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("unused") }

    func show(kind: ShapeKind, style: ShapeStyle) {
        var mark = Annotation(id: 1, kind: kind, style: style,
                              start: CGPoint(x: 48, y: 28), end: CGPoint(x: 256, y: 84))
        switch kind {
        case .line, .arrow: mark.start = CGPoint(x: 48, y: 72); mark.end = CGPoint(x: 256, y: 40)
        case .text: mark.text = "Aa"; mark.start = CGPoint(x: 40, y: max(4, 56 - style.fontSize * 0.6))
        case .step: mark.start = CGPoint(x: 152, y: 56)
        case .pen: mark.points = [CGPoint(x: 44, y: 74), CGPoint(x: 98, y: 36), CGPoint(x: 172, y: 72), CGPoint(x: 258, y: 34)]
        default: break
        }
        guard mark != annotation else { return }
        annotation = mark; needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let renderer, let context = NSGraphicsContext.current?.cgContext else { return }
        renderer.drawFrame(context)
        if let annotation { renderer.draw([annotation], in: context) }
    }
}
