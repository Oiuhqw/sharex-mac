import AppKit
import QuartzCore
import ShareXCore

/// Views under EditorView, back to front: the frozen frame (layer contents, never re-rasterised), the annotations
/// (redrawn only in dirty rects), and the chrome (dim, outline, handles, crosshair, magnifier as shape/text layers,
/// so a mouse move changes a few paths instead of repainting a Retina screen). None take events.
class PassThroughView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("unused") }
}

/// The frozen frame as the layer's contents: the GPU composites it, the CPU never redraws it.
final class FrameView: PassThroughView {
    init(frame: NSRect, image: CGImage, smooth: Bool) {
        super.init(frame: frame)
        layerContentsRedrawPolicy = .never
        let l = layer!
        l.contents = image
        l.contentsGravity = .resize
        l.magnificationFilter = smooth ? .linear : .nearest
        l.minificationFilter = smooth ? .trilinear : .nearest
        l.isOpaque = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("unused") }
}

/// The frame plus annotations, drawn exactly as the exporter draws them (blend modes need the frame beneath),
/// but only inside invalidated rects. The surface is split into 256 pt tiles, each with its own small backing
/// store: a partial update of one full-screen 30 MB Retina layer makes Core Animation copy the whole store when
/// the window server still holds the last frame, which showed up as 16 ms spikes on every few drag events.
@MainActor
final class AnnotationsView: PassThroughView {
    private let renderer: Renderer
    fileprivate var doc: EditorDocument?
    fileprivate var hiddenID: Int?
    private var previous: [Int: Annotation] = [:]
    private var previousOrder: [Int] = []
    private var tiles: [AnnotationTile] = []
    static let tile: CGFloat = 256

    init(frame: NSRect, renderer: Renderer) {
        self.renderer = renderer
        super.init(frame: frame)
        layerContentsRedrawPolicy = .never
        var y: CGFloat = 0
        while y < frame.height {
            var x: CGFloat = 0
            while x < frame.width {
                let r = CGRect(x: x, y: y, width: min(Self.tile, frame.width - x), height: min(Self.tile, frame.height - y))
                let t = AnnotationTile(frame: r, owner: self, renderer: renderer)
                addSubview(t); tiles.append(t)
                x += Self.tile
            }
            y += Self.tile
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("unused") }

    private func invalidateAll() { tiles.forEach { $0.needsDisplay = true } }
    private func invalidate(_ r: CGRect) {
        for t in tiles where t.frame.intersects(r) { t.setNeedsDisplay(t.convert(r, from: self).intersection(t.bounds).integral) }
    }

    /// Invalidates the union of what changed: old and new bounds of every added, removed or edited mark.
    func sync(_ doc: EditorDocument, hide: Int?) {
        let now = doc.annotations
        let first = self.doc == nil, hideChanged = hide != hiddenID
        let old = previous, oldOrder = previousOrder
        self.doc = doc; hiddenID = hide
        previous = Dictionary(uniqueKeysWithValues: now.map { ($0.id, $0) }); previousOrder = now.map(\.id)
        if first || hideChanged { return invalidateAll() }
        var dirty = CGRect.null
        var everything = false
        func mark(_ a: Annotation) {
            switch a.kind {
            case .text, .step, .spotlight: everything = true
            default: dirty = dirty.union(Self.reach(a))
            }
        }
        let ids = Set(now.map(\.id))
        for a in now where old[a.id] != a { mark(a); if let o = old[a.id] { mark(o) } }
        for (id, a) in old where !ids.contains(id) { mark(a) }
        // A reorder (undo of a delete, z-order change) changes overlap even when no mark changed.
        if !everything, oldOrder.filter({ ids.contains($0) }) != now.map(\.id).filter({ old[$0] != nil }) {
            for a in now { dirty = dirty.union(Self.reach(a)) }
        }
        if everything { invalidateAll() } else if !dirty.isNull { invalidate(dirty) }
    }

    /// Everything a mark can paint: stroke width, arrow head, round caps.
    static func reach(_ a: Annotation) -> CGRect {
        let pad = CGFloat(a.style.width) * 4 + 12
        return a.bounds.standardized.insetBy(dx: -pad, dy: -pad)
    }
}

@MainActor
final class AnnotationTile: PassThroughView {
    private unowned let owner: AnnotationsView
    private let renderer: Renderer
    init(frame: NSRect, owner: AnnotationsView, renderer: Renderer) {
        self.owner = owner; self.renderer = renderer
        super.init(frame: frame)
        autoresizingMask = []
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.isOpaque = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("unused") }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let doc = owner.doc else { return }
        // Draw in the parent's (frame point) coordinates.
        ctx.translateBy(x: -frame.minX, y: -frame.minY)
        let area = dirtyRect.offsetBy(dx: frame.minX, dy: frame.minY)
        renderer.drawFrame(ctx, in: area)
        renderer.draw(doc, in: ctx, hide: owner.hiddenID, clip: area)
    }
}

/// Selection chrome as layers. Every update is a few path assignments inside one action-free transaction.
@MainActor
final class ChromeView: PassThroughView {
    private let dim = CAShapeLayer(), outlineW = CAShapeLayer(), outlineB = CAShapeLayer()
    private let handles = CAShapeLayer(), selection = CAShapeLayer(), selHandles = CAShapeLayer()
    private let crosshair = CAShapeLayer(), lasso = CAShapeLayer()
    private let sizeLabel = CATextLayer(), magnifier = CALayer(), magMid = CALayer(), magLabel = CATextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layerContentsRedrawPolicy = .never
        dim.fillRule = .evenOdd; dim.fillColor = CGColor(gray: 0, alpha: 0.35)
        outlineW.strokeColor = .white; outlineB.strokeColor = CGColor(gray: 0, alpha: 1); outlineB.lineDashPattern = [4, 4]
        for l in [outlineW, outlineB] { l.fillColor = nil; l.lineWidth = 1 }
        for l in [handles, selHandles] { l.fillColor = .white; l.strokeColor = CGColor(gray: 0, alpha: 1); l.lineWidth = 1 }
        selection.fillColor = nil; selection.strokeColor = CGColor(srgbRed: 0.2, green: 0.55, blue: 1, alpha: 1)
        selection.lineWidth = 1; selection.lineDashPattern = [3, 3]
        crosshair.strokeColor = CGColor(gray: 1, alpha: 0.6); crosshair.lineWidth = 1; crosshair.fillColor = nil
        lasso.strokeColor = .white; lasso.lineWidth = 1.5; lasso.lineDashPattern = [5, 3]; lasso.fillColor = nil
        for t in [sizeLabel, magLabel] {
            t.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            t.fontSize = 11; t.foregroundColor = .white; t.alignmentMode = .left
        }
        sizeLabel.backgroundColor = CGColor(gray: 0, alpha: 0.6)
        magLabel.backgroundColor = CGColor(gray: 0, alpha: 0.7)
        magnifier.magnificationFilter = .nearest; magnifier.backgroundColor = CGColor(gray: 0, alpha: 1)
        magnifier.borderColor = .white; magnifier.borderWidth = 2
        magnifier.contentsGravity = .resize
        magMid.borderColor = CGColor(srgbRed: 1, green: 0.2, blue: 0.2, alpha: 1); magMid.borderWidth = 1
        magnifier.addSublayer(magMid)
        for l in [dim, outlineW, outlineB, handles, selection, selHandles, crosshair, lasso, sizeLabel, magnifier, magLabel] as [CALayer] {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "contents": NSNull(), "hidden": NSNull(),
                         "string": NSNull(), "frame": NSNull()]
            l.isHidden = true
            layer!.addSublayer(l)
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        for t in [sizeLabel, magLabel] { t.contentsScale = s }
    }

    struct State {
        var dimHole: CGPath?          // nil: dim nothing; empty path: dim everything
        var outline: CGRect?
        var cropHandles: CGRect?
        var selection: CGRect?
        var lasso: [CGPoint]?
        var crosshair: CGPoint?
        var magnifier: (point: CGPoint, image: CGImage?, scale: CGFloat)?
        var sizeLabel: (rect: CGRect, text: String)?
        var dimEverything = false
    }

    func apply(_ s: State) {
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        let b = bounds
        dim.frame = b
        if s.dimHole != nil || s.dimEverything {
            let p = CGMutablePath(); p.addRect(b); if let h = s.dimHole { p.addPath(h) }
            dim.path = p; dim.isHidden = false
        } else { dim.isHidden = true }

        if let r = s.outline {
            let p = CGPath(rect: r.insetBy(dx: -0.5, dy: -0.5), transform: nil)
            outlineW.path = p; outlineB.path = p
        }
        outlineW.isHidden = s.outline == nil; outlineB.isHidden = s.outline == nil
        handles.path = s.cropHandles.map(Self.handlePath); handles.isHidden = s.cropHandles == nil
        selection.path = s.selection.map { CGPath(rect: $0.insetBy(dx: -3, dy: -3), transform: nil) }
        selHandles.path = s.selection.map(Self.handlePath)
        selection.isHidden = s.selection == nil; selHandles.isHidden = s.selection == nil

        if let pts = s.lasso, pts.count > 1 {
            let p = CGMutablePath(); p.addLines(between: pts); lasso.path = p; lasso.isHidden = false
        } else { lasso.isHidden = true }

        if let c = s.crosshair {
            let p = CGMutablePath()
            p.addLines(between: [CGPoint(x: 0, y: c.y), CGPoint(x: b.width, y: c.y)])
            p.addLines(between: [CGPoint(x: c.x, y: 0), CGPoint(x: c.x, y: b.height)])
            crosshair.path = p; crosshair.isHidden = false
        } else { crosshair.isHidden = true }

        if let l = s.sizeLabel {
            let text = " \(l.text) "
            sizeLabel.string = text
            let size = Self.textSize(text)
            let y = l.rect.maxY + 4 < b.height - 16 ? l.rect.maxY + 4 : l.rect.minY + 4
            sizeLabel.frame = CGRect(x: l.rect.minX, y: y, width: size.width, height: size.height)
            sizeLabel.isHidden = false
        } else { sizeLabel.isHidden = true }

        if let m = s.magnifier { layoutMagnifier(m.point, m.image, m.scale) } else { magnifier.isHidden = true; magLabel.isHidden = true }
    }

    static let n: CGFloat = 15, zoom: CGFloat = 8

    /// 15×15 source pixels at 8x, nearest neighbour, with the pixel position underneath.
    private func layoutMagnifier(_ p: CGPoint, _ crop: CGImage?, _ s: CGFloat) {
        let side = Self.n * Self.zoom, b = bounds
        var origin = CGPoint(x: p.x + 20, y: p.y + 20)
        if origin.x + side > b.width { origin.x = p.x - 20 - side }
        if origin.y + side + 18 > b.height { origin.y = p.y - 20 - side - 18 }
        magnifier.frame = CGRect(origin: origin, size: CGSize(width: side, height: side))
        magnifier.contents = crop
        // cropping(to:) clips at image edges; place what we got where it belongs.
        let src = Self.source(p, scale: s)
        if let crop {
            let got = CGRect(x: (max(src.minX, 0) - src.minX) * Self.zoom, y: (max(src.minY, 0) - src.minY) * Self.zoom,
                             width: CGFloat(crop.width) * Self.zoom, height: CGFloat(crop.height) * Self.zoom)
            magnifier.contentsRect = CGRect(x: -got.minX / got.width, y: -got.minY / got.height,
                                            width: side / got.width, height: side / got.height)
        }
        magMid.frame = CGRect(x: (Self.n - 1) / 2 * Self.zoom, y: (Self.n - 1) / 2 * Self.zoom, width: Self.zoom, height: Self.zoom)
        magnifier.isHidden = false
        let text = " X: \(Int(p.x * s))  Y: \(Int(p.y * s)) "
        magLabel.string = text
        let size = Self.textSize(text)
        magLabel.frame = CGRect(x: origin.x, y: origin.y + side + 2, width: size.width, height: size.height)
        magLabel.isHidden = false
    }

    static func source(_ p: CGPoint, scale s: CGFloat) -> CGRect {
        CGRect(x: (p.x * s).rounded(.down) - (n - 1) / 2, y: (p.y * s).rounded(.down) - (n - 1) / 2, width: n, height: n)
    }

    private static func textSize(_ t: String) -> CGSize {
        let size = NSAttributedString(string: t, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]).size()
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    private static func handlePath(_ r: CGRect) -> CGPath {
        let p = CGMutablePath()
        for h in Handle.allCases { let c = h.point(on: r); p.addRect(CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)) }
        return p
    }
}
