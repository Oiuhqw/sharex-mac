import AppKit
import CoreGraphics
import CoreImage
import Metal
import ShareXCore

/// Draws a frozen frame plus annotations into a y-down context in frame points.
/// The overlay view and the exporter both call this, so the copied image matches the screen.
@MainActor
final class Renderer {
    let frame: CGImage
    /// Frame pixels per point.
    let scale: CGFloat
    /// One entry per effect mark, replaced in place when the mark changes.
    private var effectCache: [Int: (key: EffectKey, image: CGImage)] = [:]
    /// Smooth the frame when the view shows it at a scale other than its own (a scaled-down canvas).
    var smoothFrame = false
    /// The effect mark currently being dragged; its patches are not cached.
    var liveEffectID: Int?

    init(frame: CGImage, scale: CGFloat) { (self.frame, self.scale) = (frame, scale) }

    var pointSize: CGSize { CGSize(width: CGFloat(frame.width) / scale, height: CGFloat(frame.height) / scale) }

    func drawFrame(_ ctx: CGContext) {
        ctx.interpolationQuality = smoothFrame ? .medium : .none
        Imaging.drawUpright(frame, in: CGRect(origin: .zero, size: pointSize), ctx: ctx)
    }

    /// Only the part of the frame under `area` (view points): a crop of the same pixels, not a full-screen raster.
    func drawFrame(_ ctx: CGContext, in area: CGRect) {
        let full = CGRect(origin: .zero, size: pointSize)
        let a = area.intersection(full)
        guard !a.isNull, !a.isEmpty else { return }
        if a == full { return drawFrame(ctx) }
        let px = CGRect(x: a.minX * scale, y: a.minY * scale, width: a.width * scale, height: a.height * scale).integral
        guard let crop = frame.cropping(to: px) else { return }
        ctx.interpolationQuality = smoothFrame ? .medium : .none
        Imaging.drawUpright(crop, in: CGRect(x: px.minX / scale, y: px.minY / scale, width: px.width / scale, height: px.height / scale), ctx: ctx)
    }

    /// `clip` skips marks that cannot touch the invalidated area (CG would clip them anyway, after paying for them).
    func draw(_ doc: EditorDocument, in ctx: CGContext, hide hiddenID: Int? = nil, skip: Int? = nil, clip: CGRect? = nil) {
        let live = Set(doc.annotations.map(\.id))
        effectCache = effectCache.filter { live.contains($0.key) }
        for a in doc.annotations where a.id != hiddenID && a.id != skip {
            if let clip, a.kind != .spotlight, a.kind != .text, a.kind != .step, !AnnotationsView.reach(a).intersects(clip) { continue }
            draw(a, number: doc.stepNumber(of: a), ctx: ctx)
        }
    }

    func draw(_ a: Annotation, number: Int, ctx: CGContext) {
        let s = a.style
        let color = Imaging.cgColor(s.color, opacity: s.opacity)
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setLineWidth(CGFloat(s.width)); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setStrokeColor(color); ctx.setFillColor(color)
        switch a.kind {
        case .rectangle:
            s.filled ? ctx.fill(a.rect) : ctx.stroke(a.rect)
        case .ellipse:
            s.filled ? ctx.fillEllipse(in: a.rect) : ctx.strokeEllipse(in: a.rect)
        case .line:
            ctx.strokeLineSegments(between: [a.start, a.end])
        case .arrow:
            let len = max(10, CGFloat(s.width) * 4)
            let (l, r) = Geometry.arrowHead(tail: a.start, tip: a.end, length: len)
            ctx.strokeLineSegments(between: [a.start, a.end])
            ctx.beginPath(); ctx.move(to: a.end); ctx.addLine(to: l); ctx.addLine(to: r); ctx.closePath(); ctx.fillPath()
        case .highlighter:
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(Imaging.cgColor(s.color, opacity: s.opacity))
            ctx.fill(a.rect)
        case .pen:
            guard let first = a.points.first else { return }
            ctx.beginPath(); ctx.move(to: first)
            for p in a.points.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        case .blur, .pixelate:
            if let patch = effectPatch(a) { ctx.interpolationQuality = smoothFrame ? .medium : .none; Imaging.drawUpright(patch.image, in: patch.rect, ctx: ctx) }
        case .spotlight:
            ctx.beginPath()
            ctx.addRect(CGRect(origin: .zero, size: pointSize))
            ctx.addEllipse(in: a.rect)
            ctx.setFillColor(Imaging.cgColor(.black, opacity: min(0.9, s.strength / 100)))
            ctx.fillPath(using: .evenOdd)
        case .text:
            drawText(a, ctx: ctx)
        case .step:
            let r = a.stepRadius
            let circle = CGRect(x: a.start.x - r, y: a.start.y - r, width: 2 * r, height: 2 * r)
            ctx.fillEllipse(in: circle)
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.boldSystemFont(ofSize: CGFloat(s.fontSize)), .foregroundColor: NSColor.white])
            let size = label.size()
            withNSContext(ctx) { label.draw(at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2)) }
        }
    }

    private func drawText(_ a: Annotation, ctx: CGContext) {
        let s = a.style
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: CGFloat(s.fontSize), weight: .semibold),
            .foregroundColor: NSColor(cgColor: Imaging.cgColor(s.color, opacity: s.opacity)) ?? .red]
        let str = NSAttributedString(string: a.text, attributes: attrs)
        if s.filled {
            let box = CGRect(origin: a.start, size: str.size()).insetBy(dx: -4, dy: -2)
            ctx.setFillColor(Imaging.cgColor(.white, opacity: 0.9)); ctx.fill(box)
        }
        withNSContext(ctx) { str.draw(at: a.start) }
    }

    /// Text drawing needs an NSGraphicsContext. `ctx` is already y-down, so it is flipped.
    private func withNSContext(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The blurred/pixelated pixels for an effect, computed from the frozen frame (not from other marks)
    /// at full frame resolution. The patch replaces what is beneath it, so the redaction is real.
    /// CoreImage does the work on the GPU; one cached patch per committed mark.
    private func effectPatch(_ a: Annotation) -> (image: CGImage, rect: CGRect)? {
        guard let px = Geometry.pixelRect(a.rect, scale: scale).clamped(width: frame.width, height: frame.height) else { return nil }
        let rect = px.points(scale: scale)
        let key = EffectKey(kind: a.kind, rect: px, strength: a.style.strength)
        if let hit = effectCache[a.id], hit.key == key { return (hit.image, rect) }
        // CoreImage is y-up.
        let ciRect = px.flippedY(height: frame.height).cgRect
        // Clamp to the region's own edges so nothing outside it bleeds in and the edge is not faded.
        let src = ciFrame.cropped(to: ciRect).clampedToExtent()
        // Strength and grid placement are decided in the core (EffectMath, unit-tested); CoreImage makes the pixels.
        let anchor = EffectMath.pixelateCenter(yUp: px.flippedY(height: frame.height))
        let out: CIImage = a.kind == .blur
            ? src.applyingGaussianBlur(sigma: EffectMath.blurSigma(strength: a.style.strength, scale: scale))
            : src.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: EffectMath.pixelateBlock(strength: a.style.strength, scale: scale),
                                                             kCIInputCenterKey: CIVector(x: anchor.x, y: anchor.y)])
        guard let cg = ciContext.createCGImage(out.cropped(to: ciRect), from: ciRect, format: .RGBA8,
                                               colorSpace: frame.colorSpace ?? Imaging.colorSpace) else { return nil }
        // While a mark is drawn, moved or resized every drag event has a new rect; don't cache those.
        if a.id != liveEffectID { effectCache[a.id] = (key, cg) }
        return (cg, rect)
    }

    /// The patch for the mark being dragged: one entry, reused while its pixel rect and strength are unchanged
    /// (pointer jitter under a pixel, a pure resize back to a seen size), never stored in effectCache.
    private var liveCache: (key: EffectKey, image: CGImage)?
    func livePatch(_ a: Annotation) -> (image: CGImage, rect: CGRect)? {
        guard let px = Geometry.pixelRect(a.rect, scale: scale).clamped(width: frame.width, height: frame.height) else { return nil }
        let key = EffectKey(kind: a.kind, rect: px, strength: a.style.strength)
        if let c = liveCache, c.key == key { return (c.image, px.points(scale: scale)) }
        guard let p = effectPatch(a) else { return nil }
        liveCache = (key, p.image)
        return p
    }

    private struct EffectKey: Hashable {
        let kind: ShapeKind, rect: PixelRect, strength: Double
    }
    /// One Metal-backed CIContext for the whole app: creating one costs a pipeline/shader-cache setup per capture.
    private static let sharedCI: CIContext = {
        let opts: [CIContextOption: Any] = [.cacheIntermediates: false, .workingColorSpace: Imaging.colorSpace]
        if let dev = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: dev, options: opts) }
        return CIContext(options: opts)
    }()
    private var ciContext: CIContext { Self.sharedCI }
    private lazy var ciFrame = CIImage(cgImage: frame)
}
