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
    private var annotations: [Annotation]?
    private var hiddenID: Int?
    private var liveID: Int?
    private var previous: [Int: Annotation] = [:]
    private var previousOrder: [Int] = []
    private(set) var drawsFrame = false
    #if SHAREX_E2E
    private(set) var e2eSyncCount = 0
    #endif

    init(frame: NSRect, renderer: Renderer) {
        self.renderer = renderer
        super.init(frame: frame)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.isOpaque = false
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("unused") }

    /// Invalidates the union of what changed: old and new bounds of every added, removed or edited mark.
    func sync(_ doc: EditorDocument, hide: Int?, live: Int? = nil) {
        #if SHAREX_E2E
        e2eSyncCount += 1
        #endif
        let privacyDirty = renderer.synchronize(doc)
        let now = doc.annotations.filter { $0.id != live }
        defer {
            annotations = doc.annotations; hiddenID = hide; liveID = live
            previous = Dictionary(uniqueKeysWithValues: now.map { ($0.id, $0) }); previousOrder = now.map(\.id)
        }
        let wantFrame = doc.annotations.contains { $0.kind == .highlighter && $0.id != live }
        if wantFrame != drawsFrame { drawsFrame = wantFrame; layer?.isOpaque = wantFrame; needsDisplay = true; return }
        guard annotations != nil else { needsDisplay = true; return }
        if hide != hiddenID { needsDisplay = true; return }
        var dirty = privacyDirty ?? .null
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
        guard let ctx = NSGraphicsContext.current?.cgContext, let annotations else { return }
        let area = dirtyRect
        if drawsFrame { renderer.drawFrame(ctx, in: area) } else { ctx.clear(area) }
        renderer.draw(annotations, in: ctx, hide: hiddenID, skip: liveID, clip: area)
    }
}

/// The mark under the mouse during a drag, as GPU-composited layers: a shape-path change per event instead of
/// a CPU raster of the annotation bitmap. Highlighter uses multiply compositing; blur/pixelate show the live
/// CoreImage patch as layer contents.
@MainActor
final class LiveMarkView: PassThroughView {
    private let stroke = CAShapeLayer(), head = CAShapeLayer(), highlight = CAShapeLayer(), patch = CALayer()
    private let failedMasks = CAShapeLayer()
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
        showFailedMasks(renderer.redactionFailureRects)
        for l in [stroke, head, highlight, patch] as [CALayer] { l.isHidden = true }
        patch.contents = nil; patch.backgroundColor = nil; patch.mask = nil
        guard let a else { renderer.endLiveEffect(); return }
        if let guardRect = renderer.liveGuard(for: a) {
            renderer.discardLivePatch()
            patch.frame = guardRect; patch.backgroundColor = CGColor(gray: 0, alpha: 1); patch.isHidden = false
            return
        }
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

    func releaseResources() {
        patch.contents = nil; patch.mask = nil; patch.backgroundColor = nil
        for l in [stroke, head, highlight, patch, failedMasks] as [CALayer] { l.isHidden = true }
        shownFailureRects = []; failedMasks.path = nil
    }

    #if SHAREX_E2E
    var e2eRetainedPatchBytes: Int {
        guard let contents = patch.contents else { return 0 }
        return Imaging.retainedBytes(of: contents as! CGImage) ?? 0
    }
    #endif

    func showFailedMasks(_ rects: [CGRect]) {
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
    private let sizeLabel = CATextLayer(), magnifier = CALayer(), magImage = CALayer(), magMid = CALayer(), magLabel = CATextLayer()
    private var magSize = CGSize.zero
    private var magOrigin = CGPoint.zero
    var reservedTop: CGFloat = 0

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
        // Container (black where the source runs off the image, white border) holding the image layer and the
        // centre-cell marker. The frozen frame is the image layer's contents once per session; a move changes only
        // its contentsRect and frame, so hover never crops or allocates an image.
        magnifier.backgroundColor = CGColor(gray: 0, alpha: 1); magnifier.masksToBounds = true
        magImage.magnificationFilter = .nearest; magImage.minificationFilter = .nearest
        magImage.contentsGravity = .resize
        magMid.borderColor = CGColor(srgbRed: 1, green: 0.2, blue: 0.2, alpha: 1); magMid.borderWidth = 1
        let rim = CALayer(); rim.borderColor = .white; rim.borderWidth = 2
        rim.frame = CGRect(x: 0, y: 0, width: Self.n * Self.zoom, height: Self.n * Self.zoom)
        for l in [magImage, magMid, rim] {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "contentsRect": NSNull(), "frame": NSNull(), "contents": NSNull()]
            magnifier.addSublayer(l)
        }
        // Above every other chrome layer.
        magnifier.zPosition = 1000; magLabel.zPosition = 1000
        for l in [dim, outlineW, outlineB, handles, selection, selHandles, crosshair, lasso, sizeLabel, magnifier, magLabel] as [CALayer] {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "contents": NSNull(), "hidden": NSNull(),
                         "string": NSNull(), "frame": NSNull(), "contentsRect": NSNull()]
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

    /// The frozen frame the loupe samples; set once per overlay.
    func setMagnifierSource(_ image: CGImage, originPixels: CGPoint = .zero) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        magImage.contents = image; magSize = CGSize(width: image.width, height: image.height); magOrigin = originPixels
        CATransaction.commit()
    }

    func releaseResources() {
        magImage.contents = nil; magSize = .zero
        magnifier.isHidden = true; magLabel.isHidden = true
    }

    struct State {
        var dimHole: CGPath?          // nil: dim nothing; empty path: dim everything
        var outline: CGRect?
        var cropHandles: CGRect?
        var selection: CGRect?
        var lasso: [CGPoint]?
        var crosshair: CGPoint?
        var magnifier: (point: CGPoint, scale: CGFloat)?
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

        if let m = s.magnifier { layoutMagnifier(m.point, m.scale) } else { magnifier.isHidden = true; magLabel.isHidden = true }
    }

    static let n: CGFloat = 15, zoom: CGFloat = 8

    /// 15×15 source pixels at 8x, nearest neighbour, with the pixel position underneath.
    private func layoutMagnifier(_ p: CGPoint, _ s: CGFloat) {
        let side = Self.n * Self.zoom, b = bounds, gap: CGFloat = 20, label: CGFloat = 18
        // Default below-right of the cursor; flip on whichever axis would overflow, then clamp to all four edges.
        var o = CGPoint(x: p.x + gap, y: p.y + gap)
        if o.x + side > b.width { o.x = p.x - gap - side }
        if o.y + side + label > b.height { o.y = p.y - gap - side - label }
        o.x = min(max(o.x, 0), max(0, b.width - side)); o.y = min(max(o.y, reservedTop), max(0, b.height - side - label))
        magnifier.frame = CGRect(origin: o, size: CGSize(width: side, height: side))
        // Only the part of the source square inside the image is drawn; the rest stays black.
        let src = Self.source(p, scale: s).offsetBy(dx: -magOrigin.x, dy: -magOrigin.y)
        let vis = src.intersection(CGRect(origin: .zero, size: magSize))
        if vis.isNull || vis.isEmpty || magSize.width == 0 { magImage.isHidden = true } else {
            magImage.isHidden = false
            magImage.frame = CGRect(x: (vis.minX - src.minX) * Self.zoom, y: (vis.minY - src.minY) * Self.zoom,
                                    width: vis.width * Self.zoom, height: vis.height * Self.zoom)
            magImage.contentsRect = Self.unitRect(vis, in: magSize)
        }
        magMid.frame = CGRect(x: (Self.n - 1) / 2 * Self.zoom, y: (Self.n - 1) / 2 * Self.zoom, width: Self.zoom, height: Self.zoom)
        magnifier.isHidden = false
        let text = " X: \(Int(p.x * s))  Y: \(Int(p.y * s)) "
        if (magLabel.string as? String) != text { magLabel.string = text; magLabelSize = Self.textSize(text) }
        magLabel.frame = CGRect(x: o.x, y: o.y + side + 2, width: magLabelSize.width, height: magLabelSize.height)
        magLabel.isHidden = false
    }
    private var magLabelSize = CGSize.zero
    #if SHAREX_E2E
    /// E2E seam: what the loupe shows (visible, frame in view points, label, sampled unit rect, source size).
    var e2eLoupe: (visible: Bool, frame: CGRect, label: String, contentsRect: CGRect, source: CGSize) {
        (!magnifier.isHidden, magnifier.frame, (magLabel.string as? String) ?? "", magImage.contentsRect, magSize)
    }
    var e2eSizeLabel: String { (sizeLabel.string as? String)?.trimmingCharacters(in: .whitespaces) ?? "" }
    #endif

    /// `r` in y-down image pixels as a contentsRect. The layer tree is flipped (y-down), and CA maps contentsRect
    /// in the layer's own geometry, so y stays top-down.
    static let contentsRectFlipY = false
    static func unitRect(_ r: CGRect, in size: CGSize) -> CGRect {
        let y = contentsRectFlipY ? size.height - r.maxY : r.minY
        return CGRect(x: r.minX / size.width, y: y / size.height, width: r.width / size.width, height: r.height / size.height)
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

