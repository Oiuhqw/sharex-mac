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

/// Committed annotations, redrawn only inside invalidated rects. Transparent over FrameView (no frame raster)
/// unless a highlighter is present: its multiply blend needs the frame beneath in the same bitmap.
/// The mark being dragged (`live`) is excluded here and shown by LiveMarkView; it is drawn into this bitmap
/// once, on mouse-up, when `live` clears and the diff sees it as added.
@MainActor
final class AnnotationsView: PassThroughView {
    private let renderer: Renderer
    private var doc: EditorDocument?
    private var hiddenID: Int?
    private var liveID: Int?
    private var previous: [Int: Annotation] = [:]
    private var previousOrder: [Int] = []
    private(set) var drawsFrame = false

    init(frame: NSRect, renderer: Renderer) {
        self.renderer = renderer
        super.init(frame: frame)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.isOpaque = false
        renderer.redactionFailuresNeedDisplay = { [weak self] rect in
            self?.setNeedsDisplay(rect.integral)
            // A transition can occur inside draw; request the full repaint again after that pass finishes.
            DispatchQueue.main.async { [weak self] in self?.setNeedsDisplay(rect.integral) }
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("unused") }

    /// Invalidates the union of what changed: old and new bounds of every added, removed or edited mark.
    func sync(_ doc: EditorDocument, hide: Int?, live: Int? = nil) {
        let now = doc.annotations.filter { $0.id != live }
        defer {
            self.doc = doc; hiddenID = hide; liveID = live
            previous = Dictionary(uniqueKeysWithValues: now.map { ($0.id, $0) }); previousOrder = now.map(\.id)
        }
        let wantFrame = doc.annotations.contains { $0.kind == .highlighter && $0.id != live }
        if wantFrame != drawsFrame { drawsFrame = wantFrame; layer?.isOpaque = wantFrame; needsDisplay = true; return }
        guard self.doc != nil else { needsDisplay = true; return }
        if hide != hiddenID { needsDisplay = true; return }
        var dirty = CGRect.null
        var everything = false
        func mark(_ a: Annotation) {
            switch a.kind {
            case .text, .step, .spotlight: everything = true
            default: dirty = dirty.union(Self.reach(a))
            }
        }
        let ids = Set(now.map(\.id))
        for a in now where previous[a.id] != a { mark(a); if let old = previous[a.id] { mark(old) } }
        for (id, a) in previous where !ids.contains(id) { mark(a) }
        // A reorder (undo of a delete, z-order change) changes overlap even when no mark changed.
        if !everything, previousOrder != now.map(\.id).filter({ previous[$0] != nil }) {
            for a in now { dirty = dirty.union(Self.reach(a)) }
        }
        if everything { needsDisplay = true } else if !dirty.isNull { setNeedsDisplay(dirty.integral) }
    }

    /// Everything a mark can paint: stroke width, arrow head, round caps.
    static func reach(_ a: Annotation) -> CGRect {
        let pad = CGFloat(a.style.width) * 4 + 12
        return a.bounds.standardized.insetBy(dx: -pad, dy: -pad)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let doc else { return }
        let area = dirtyRect
        if drawsFrame { renderer.drawFrame(ctx, in: area) } else { ctx.clear(area) }
        renderer.draw(doc, in: ctx, hide: hiddenID, skip: liveID, clip: area)
    }
}

/// The mark under the mouse during a drag, as GPU-composited layers: a shape-path change per event instead of
/// a CPU raster of the annotation bitmap. Highlighter uses multiply compositing; blur/pixelate show the live
/// CoreImage patch as layer contents.
@MainActor
final class LiveMarkView: PassThroughView {
    private let stroke = CAShapeLayer(), head = CAShapeLayer(), highlight = CAShapeLayer(), patch = CALayer()
    private let failedMasks = CAShapeLayer()
    private weak var observedRenderer: Renderer?
    private var shownFailureRects: [CGRect] = []
    static func supports(_ k: ShapeKind) -> Bool {
        switch k {
        case .rectangle, .ellipse, .line, .arrow, .pen, .highlighter, .blur, .pixelate: true
        default: false
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layerContentsRedrawPolicy = .never
        layer?.isOpaque = false
        stroke.lineCap = .round; stroke.lineJoin = .round
        highlight.compositingFilter = "multiplyBlendMode"
        patch.contentsGravity = .resize
        for l in [stroke, head, highlight, patch] as [CALayer] {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "contents": NSNull(), "hidden": NSNull(),
                         "frame": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull()]
            l.isHidden = true
            layer!.addSublayer(l)
        }
        failedMasks.fillColor = CGColor(gray: 0, alpha: 1)
        failedMasks.actions = ["path": NSNull(), "hidden": NSNull()]
        failedMasks.isHidden = true
        layer!.addSublayer(failedMasks)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("unused") }

    func show(_ a: Annotation?, renderer: Renderer) {
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        if observedRenderer !== renderer {
            observedRenderer?.redactionFailuresChanged = nil
            observedRenderer = renderer
            renderer.redactionFailuresChanged = { [weak self] in self?.showFailedMasks($0) }
        }
        showFailedMasks(renderer.redactionFailureRects)
        for l in [stroke, head, highlight, patch] as [CALayer] { l.isHidden = true }
        guard let a else { return }
        let s = a.style, color = Imaging.cgColor(s.color, opacity: s.opacity)
        stroke.lineWidth = CGFloat(s.width); stroke.strokeColor = color; stroke.fillColor = nil
        let p = CGMutablePath()
        switch a.kind {
        case .rectangle:
            p.addRect(a.rect)
            if s.filled { stroke.fillColor = color; stroke.strokeColor = nil }
        case .ellipse:
            p.addEllipse(in: a.rect)
            if s.filled { stroke.fillColor = color; stroke.strokeColor = nil }
        case .line:
            p.addLines(between: [a.start, a.end])
        case .arrow:
            p.addLines(between: [a.start, a.end])
            let (l, r) = Geometry.arrowHead(tail: a.start, tip: a.end, length: max(10, CGFloat(s.width) * 4))
            let h = CGMutablePath(); h.addLines(between: [a.end, l, r]); h.closeSubpath()
            head.path = h; head.fillColor = color; head.isHidden = false
        case .pen:
            if a.points.count > 1 { p.addLines(between: a.points) }
        case .highlighter:
            highlight.path = CGPath(rect: a.rect, transform: nil); highlight.fillColor = color; highlight.isHidden = false
            return
        case .blur, .pixelate:
            if let pt = renderer.livePatch(a) {
                patch.contents = pt.image; patch.frame = pt.rect
                patch.backgroundColor = nil
            } else if let rect = renderer.redactionBounds(a) {
                // Match the export fallback without allocating another image after a render failure.
                patch.contents = nil; patch.frame = rect
                patch.backgroundColor = CGColor(gray: 0, alpha: 1)
            } else { return }
            patch.magnificationFilter = renderer.smoothFrame ? .linear : .nearest
            patch.isHidden = false
            return
        default: return
        }
        stroke.path = p; stroke.isHidden = false
    }

    private func showFailedMasks(_ rects: [CGRect]) {
        guard rects != shownFailureRects else { return }
        shownFailureRects = rects
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        let path = CGMutablePath()
        for rect in rects { path.addRect(rect) }
        failedMasks.path = path
        failedMasks.isHidden = rects.isEmpty
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

