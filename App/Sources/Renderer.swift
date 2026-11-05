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
    private struct CachedPatch {
        let key: EffectKey
        let image: CGImage
        let bytes: Int
        var use: UInt64
    }
    private var effectCache: [Int: CachedPatch] = [:]
    private var cacheBytes = 0
    private var cacheClock: UInt64 = 0
    private static let cacheLimit = 64 * 1024 * 1024
    private static let cacheEntries = 128
    private static let effectPixels = 16 * 1024 * 1024
    private static let liveBytesLimit = 16 * 1024 * 1024
    private static let intersectionLimit = 64
    private static let dependencyScanLimit = 1024
    private struct Protection {
        let id: Int
        let bounds: PixelRect
    }
    private var protections: [Protection] = []
    private var effectKeys: [Int: EffectKey] = [:]
    /// Smooth the frame when the view shows it at a scale other than its own (a scaled-down canvas).
    var smoothFrame = false
    /// The effect mark currently being dragged; its patches are not cached.
    var liveEffectID: Int?
    private var failedRedactions: [Int: CGRect] = [:]
    var redactionFailureRects: [CGRect] { Array(failedRedactions.values) }
    var redactionFailuresChanged: (([CGRect]) -> Void)?
    var redactionFailuresNeedDisplay: ((CGRect) -> Void)?
    #if SHAREX_E2E
    /// Simulates failure to materialize an uncached CoreImage effect.
    var e2eRejectEffectImage = false
    var e2eRejectedEffectIDs: Set<Int> = []
    var e2eCacheBytes: Int { cacheBytes }
    var e2eCacheEntryCount: Int { effectCache.count }
    var e2eLiveBytes: Int { liveCache.flatMap { Imaging.retainedBytes(of: $0.image) } ?? 0 }
    static func e2eClearContextCaches() { sharedCI.clearCaches() }
    #endif

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
        synchronize(doc)
        var step = 0
        for a in doc.annotations {
            // Hidden and clipped marks still participate in the document's step numbering.
            if a.kind == .step { step += 1 }
            guard a.id != hiddenID && a.id != skip else { continue }
            if let clip, a.kind != .spotlight, a.kind != .text, a.kind != .step, !AnnotationsView.reach(a).intersects(clip) { continue }
            draw(a, number: step, ctx: ctx)
        }
        coverRedactionFailures(in: ctx, hide: hiddenID, skip: skip)
    }

    #if SHAREX_E2E
    /// The pre-optimization loop for pixel-equivalence tests and paired Release measurements.
    func e2eDrawLegacy(_ doc: EditorDocument, in ctx: CGContext, hide hiddenID: Int? = nil, skip: Int? = nil, clip: CGRect? = nil) {
        synchronize(doc)
        for a in doc.annotations where a.id != hiddenID && a.id != skip {
            if let clip, a.kind != .spotlight, a.kind != .text, a.kind != .step, !AnnotationsView.reach(a).intersects(clip) { continue }
            draw(a, number: doc.stepNumber(of: a), ctx: ctx)
        }
        coverRedactionFailures(in: ctx, hide: hiddenID, skip: skip)
    }
    #endif

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
            if let patch = effectPatch(a) {
                clipPriorProtection(for: a.id, rect: patch.rect, in: ctx)
                ctx.interpolationQuality = smoothFrame ? .medium : .none
                Imaging.drawUpright(patch.image, in: patch.rect, ctx: ctx)
            } else if let rect = redactionBounds(a) {
                coverRedaction(rect, in: ctx)
            }
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

    func pixelArea(_ rect: CGRect) -> PixelRect? {
        Geometry.capturePixels(rect, scale: scale, width: frame.width, height: frame.height)
    }

    func redactionBounds(_ a: Annotation) -> CGRect? { pixelArea(a.rect)?.points(scale: scale) }

    private func protectionBounds(_ a: Annotation) -> PixelRect? {
        if a.kind == .blur || a.kind == .pixelate { return pixelArea(a.rect) }
        guard a.kind == .rectangle, a.style.filled, a.style.color.a * a.style.opacity == 1 else { return nil }
        return Geometry.fullyCoveredPixels(a.rect, scale: scale, width: frame.width, height: frame.height)
    }

    @discardableResult
    func synchronize(_ doc: EditorDocument) -> CGRect? {
        var prior: [Protection] = []
        var next: [Int: EffectKey] = [:]
        for a in doc.annotations {
            guard let area = protectionBounds(a) else { continue }
            if a.kind == .blur || a.kind == .pixelate {
                var intersections: [PixelRect] = []
                var exceeded = false
                for (index, p) in prior.enumerated() {
                    if index == Self.dependencyScanLimit { exceeded = true; break }
                    guard let overlap = area.intersection(p.bounds) else { continue }
                    if intersections.count == Self.intersectionLimit { exceeded = true; break }
                    intersections.append(overlap)
                }
                next[a.id] = EffectKey(kind: a.kind, rect: area, strength: a.style.strength,
                                      prior: intersections, exceeded: exceeded)
            }
            prior.append(Protection(id: a.id, bounds: area))
        }
        var dirty = CGRect.null
        for id in Set(effectKeys.keys).union(next.keys) where effectKeys[id] != next[id] {
            if let old = effectKeys[id] { dirty = dirty.union(old.rect.points(scale: scale)) }
            if let new = next[id] { dirty = dirty.union(new.rect.points(scale: scale)) }
            removeCached(id)
            if failedRedactions[id] != nil { setRedactionFailure(id, rect: next[id]?.rect.points(scale: scale)) }
        }
        effectKeys = next
        protections = prior
        return dirty.isNull ? nil : dirty
    }

    func sourceIsProtected(_ pixels: CGRect) -> Bool {
        protections.contains { $0.bounds.cgRect.intersects(pixels) }
    }

    func liveGuard(for a: Annotation) -> CGRect? {
        guard let own = protectionBounds(a), let index = protections.firstIndex(where: { $0.id == a.id }) else { return nil }
        var guardRect = CGRect.null
        for (i, p) in protections.enumerated() where p.id != a.id && p.bounds.intersection(own) != nil {
            guardRect = guardRect.union(own.points(scale: scale))
            if i > index, effectKeys[p.id] != nil { guardRect = guardRect.union(p.bounds.points(scale: scale)) }
        }
        return guardRect.isNull ? nil : guardRect
    }

    private func clipPriorProtection(for id: Int, rect: CGRect, in ctx: CGContext) {
        ctx.setShouldAntialias(false)
        for area in effectKeys[id]?.prior ?? [] {
            ctx.beginPath(); ctx.addRect(rect); ctx.addRect(area.points(scale: scale)); ctx.clip(using: .evenOdd)
        }
    }

    private func removeCached(_ id: Int) {
        if let entry = effectCache.removeValue(forKey: id) { cacheBytes -= entry.bytes }
    }

    private func cache(_ image: CGImage, key: EffectKey, id: Int) {
        removeCached(id)
        guard let bytes = Imaging.retainedBytes(of: image), bytes <= Self.cacheLimit else { return }
        while cacheBytes + bytes > Self.cacheLimit || effectCache.count >= Self.cacheEntries {
            guard let oldest = effectCache.min(by: { $0.value.use < $1.value.use })?.key else { break }
            removeCached(oldest)
        }
        cacheClock &+= 1
        effectCache[id] = CachedPatch(key: key, image: image, bytes: bytes, use: cacheClock)
        cacheBytes += bytes
    }

    func endLiveEffect() {
        liveCache = nil
        liveEffectID = nil
        fastLivePreview = false
    }

    func discardLivePatch() { liveCache = nil }

    func releaseTransientResources() {
        endLiveEffect()
        effectCache.removeAll(); cacheBytes = 0
        failedRedactions.removeAll(); effectKeys.removeAll(); protections.removeAll()
        redactionFailuresChanged = nil; redactionFailuresNeedDisplay = nil
    }

    private func setRedactionFailure(_ id: Int, rect: CGRect?) {
        let old = failedRedactions[id]
        guard old != rect else { return }
        failedRedactions[id] = rect
        redactionFailuresChanged?(redactionFailureRects)
        let dirty = (old ?? .null).union(rect ?? .null)
        if !dirty.isNull { redactionFailuresNeedDisplay?(dirty) }
    }

    private func coverRedaction(_ rect: CGRect, in ctx: CGContext) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setBlendMode(.copy); ctx.setAlpha(1); ctx.setShouldAntialias(false)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(rect)
    }

    private func coverRedactionFailures(in ctx: CGContext, hide: Int?, skip: Int?) {
        for (id, rect) in failedRedactions where id != hide && id != skip { coverRedaction(rect, in: ctx) }
    }

    private func key(for a: Annotation, area: PixelRect) -> EffectKey {
        let prepared = effectKeys[a.id]
        return EffectKey(kind: a.kind, rect: area, strength: a.style.strength,
                         prior: prepared?.prior ?? [], exceeded: prepared?.exceeded ?? false)
    }

    private func effectSource(_ key: EffectKey) -> CIImage? {
        let area = key.rect
        let ciRect = area.flippedY(height: frame.height).cgRect
        guard !key.exceeded, Imaging.allocationBytes(width: area.w, height: area.h, maximumPixels: Self.effectPixels) != nil,
              let source = frame.cropping(to: area.cgRect),
              let ctx = Imaging.context(width: area.w, height: area.h, flipped: true) else { return nil }
        ctx.setShouldAntialias(false); ctx.interpolationQuality = .none
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: area.w, height: area.h))
        Imaging.drawUpright(source, in: CGRect(x: 0, y: 0, width: area.w, height: area.h), ctx: ctx)
        ctx.setBlendMode(.copy)
        for covered in key.prior {
            ctx.fill(CGRect(x: covered.x - area.x, y: covered.y - area.y, width: covered.w, height: covered.h))
        }
        guard let sanitized = ctx.makeImage() else { return nil }
        return CIImage(cgImage: sanitized).transformed(by: CGAffineTransform(translationX: ciRect.minX, y: ciRect.minY)).clampedToExtent()
    }

    private func effectPatch(_ a: Annotation, retain: Bool = true) -> (image: CGImage, rect: CGRect)? {
        guard let px = pixelArea(a.rect) else { setRedactionFailure(a.id, rect: nil); return nil }
        let rect = px.points(scale: scale), key = key(for: a, area: px)
        if var hit = effectCache[a.id], hit.key == key {
            cacheClock &+= 1; hit.use = cacheClock; effectCache[a.id] = hit
            setRedactionFailure(a.id, rect: nil); return (hit.image, rect)
        }
        guard let src = effectSource(key) else { setRedactionFailure(a.id, rect: rect); return nil }
        let ciRect = px.flippedY(height: frame.height).cgRect
        let anchor = EffectMath.pixelateCenter(yUp: px.flippedY(height: frame.height))
        let out: CIImage = a.kind == .blur
            ? src.applyingGaussianBlur(sigma: EffectMath.blurSigma(strength: a.style.strength, scale: scale))
            : src.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: EffectMath.pixelateBlock(strength: a.style.strength, scale: scale),
                                                             kCIInputCenterKey: CIVector(x: anchor.x, y: anchor.y)])
        #if SHAREX_E2E
        if e2eRejectEffectImage || e2eRejectedEffectIDs.contains(a.id) { setRedactionFailure(a.id, rect: rect); return nil }
        #endif
        guard let cg = ciContext.createCGImage(out.cropped(to: ciRect), from: ciRect, format: .RGBA8,
                                               colorSpace: frame.colorSpace ?? Imaging.colorSpace),
              Imaging.accepts(cg), let bytes = Imaging.retainedBytes(of: cg), bytes <= Self.effectPixels * 4 else {
            setRedactionFailure(a.id, rect: rect); return nil
        }
        setRedactionFailure(a.id, rect: nil)
        if retain, a.id != liveEffectID { cache(cg, key: key, id: a.id) }
        return (cg, rect)
    }

    private var liveCache: (key: EffectKey, image: CGImage, preview: Bool)?
    var fastLivePreview = false
    func livePatch(_ a: Annotation) -> (image: CGImage, rect: CGRect)? {
        guard let px = pixelArea(a.rect) else { liveCache = nil; setRedactionFailure(a.id, rect: nil); return nil }
        let key = key(for: a, area: px), preview = fastLivePreview && a.kind == .blur && key.prior.isEmpty && !key.exceeded
        if let c = liveCache, c.key == key, c.preview == preview { setRedactionFailure(a.id, rect: nil); return (c.image, px.points(scale: scale)) }
        liveCache = nil
        let patch: (image: CGImage, rect: CGRect)?
        if preview, let small = blurPreview(a, px) { patch = small }
        else if Imaging.allocationBytes(width: px.w, height: px.h, maximumPixels: Self.liveBytesLimit / 4) != nil {
            patch = effectPatch(a, retain: false)
        } else { patch = nil }
        guard let patch, let bytes = Imaging.retainedBytes(of: patch.image), bytes <= Self.liveBytesLimit else {
            setRedactionFailure(a.id, rect: px.points(scale: scale)); return nil
        }
        setRedactionFailure(a.id, rect: nil)
        liveCache = (key, patch.image, preview)
        return patch
    }

    /// Downsample by f (sigma/f stays >= 4 px), blur at sigma/f, render the small patch. ~f² fewer pixels.
    private func blurPreview(_ a: Annotation, _ px: PixelRect) -> (image: CGImage, rect: CGRect)? {
        let sigma = EffectMath.blurSigma(strength: a.style.strength, scale: scale)
        let f = min(4, floor(sigma / 4))
        guard f >= 2 else { return nil }
        #if SHAREX_E2E
        if e2eRejectEffectImage || e2eRejectedEffectIDs.contains(a.id) { return nil }
        #endif
        let ciRect = px.flippedY(height: frame.height).cgRect
        let k = 1 / f
        let matte = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: ciRect)
        let small = ciFrame.cropped(to: ciRect).composited(over: matte).clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
            .applyingGaussianBlur(sigma: sigma / f)
        let sr = CGRect(x: ciRect.minX * k, y: ciRect.minY * k, width: ciRect.width * k, height: ciRect.height * k).integral
        guard let dimensions = Imaging.pixelDimensions(size: sr.size, scale: 1),
              Imaging.allocationBytes(width: dimensions.width, height: dimensions.height, maximumPixels: Self.liveBytesLimit / 4) != nil,
              let cg = ciContext.createCGImage(small.cropped(to: sr), from: sr, format: .RGBA8,
                                               colorSpace: frame.colorSpace ?? Imaging.colorSpace),
              let bytes = Imaging.retainedBytes(of: cg), bytes <= Self.liveBytesLimit else { return nil }
        return (cg, px.points(scale: scale))
    }

    private struct EffectKey: Hashable {
        let kind: ShapeKind, rect: PixelRect, strength: Double
        let prior: [PixelRect]
        let exceeded: Bool
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

