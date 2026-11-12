#if SHAREX_E2E
import AppKit
import ShareXCore

@MainActor
enum E2EPrivacy {
    private static let size = CGSize(width: 256, height: 192)
    private static var crop: CGRect { CGRect(origin: .zero, size: size) }

    @discardableResult
    private static func add(_ kind: ShapeKind, _ rect: CGRect, doc: inout EditorDocument) -> Int {
        if kind == .rectangle {
            var style = doc.style(for: kind)
            style.filled = true; style.color = .black; style.opacity = 1
            doc.styles[kind] = style
        } else {
            var style = doc.style(for: kind)
            style.strength = doc.annotations.isEmpty ? 32 : 8
            doc.styles[kind] = style
        }
        doc.beginDrag()
        let id = doc.addShape(kind, at: rect.origin)
        doc.extendShape(id, to: CGPoint(x: rect.maxX, y: rect.maxY)); doc.endDrag()
        return id
    }

    private static func source(scale: CGFloat, hidden: [CGRect], changed: Bool) -> CGImage? {
        guard let checker = E2E.checker(Int(size.width * scale), Int(size.height * scale)),
              let ctx = Imaging.context(width: checker.width, height: checker.height, flipped: true) else { return nil }
        Imaging.drawUpright(checker, in: CGRect(x: 0, y: 0, width: checker.width, height: checker.height), ctx: ctx)
        if changed {
            ctx.scaleBy(x: scale, y: scale)
            ctx.setShouldAntialias(false); ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0.7, alpha: 1))
            for rect in hidden { ctx.fill(rect) }
        }
        return ctx.makeImage()
    }

    private static func equal(_ a: E2E.Bitmap, _ b: E2E.Bitmap, where include: (Int, Int) -> Bool) -> Bool {
        guard a.w == b.w, a.h == b.h else { return false }
        for y in 0..<a.h { for x in 0..<a.w where include(x, y) {
            let i = (y * a.w + x) * 4
            if a.px[i..<(i + 4)] != b.px[i..<(i + 4)] { return false }
        } }
        return true
    }

    private static func inside(_ x: Int, _ y: Int, _ areas: [PixelRect]) -> Bool {
        areas.contains { x >= $0.x && x < $0.maxX && y >= $0.y && y < $0.maxY }
    }

    private static func flatten(_ renderer: Renderer, _ doc: EditorDocument) -> E2E.Bitmap? {
        Export.flatten(renderer: renderer, doc: doc, crop: crop, lasso: nil).map(E2E.bitmap)
    }

    static func run() {
        for scale in [CGFloat(1), CGFloat(2)] {
            for first in [ShapeKind.blur, .pixelate, .rectangle] {
                for second in [ShapeKind.blur, .pixelate] { overlap(first, second, scale: scale) }
            }
            overlappingProtections(scale: scale)
            mutation(scale: scale)
            overlapBudget(scale: scale)
        }
        cacheEviction()
        dependencyScanBudget()
        fractionalOpaqueProtection()
        editorCommit()
        allocationRefusal()
    }

    private static func overlap(_ first: ShapeKind, _ second: ShapeKind, scale: CGFloat) {
        let name = "\(first.rawValue)-\(second.rawValue)-\(Int(scale))x"
        let a = CGRect(x: 20, y: 20, width: 120, height: 110), b = CGRect(x: 90, y: 70, width: 140, height: 105)
        var doc = EditorDocument()
        let firstID = add(first, a, doc: &doc)
        let prior = doc
        let secondID = add(second, b, doc: &doc)
        let areas = [Geometry.pixelRect(a, scale: scale)]
        guard let imageA = source(scale: scale, hidden: [a], changed: false),
              let imageB = source(scale: scale, hidden: [a], changed: true) else {
            E2E.record("privacy-pair-setup-\(name)", false); return
        }
        let rA = Renderer(frame: imageA, scale: scale), rB = Renderer(frame: imageB, scale: scale)
        guard let firstA = flatten(Renderer(frame: imageA, scale: scale), prior),
              let firstB = flatten(Renderer(frame: imageB, scale: scale), prior),
              let fullA = flatten(rA, doc), let fullB = flatten(rB, doc) else {
            E2E.record("privacy-pair-materialize-\(name)", false); return
        }
        E2E.record("privacy-sanitized-neighbors-\(name)", equal(fullA, fullB) { !inside($0, $1, areas) })
        E2E.record("privacy-first-protection-\(name)",
                   equal(fullA, firstA) { inside($0, $1, areas) } && equal(fullB, firstB) { inside($0, $1, areas) })
        if first != .rectangle {
            let failedA = Renderer(frame: imageA, scale: scale), failedB = Renderer(frame: imageB, scale: scale)
            failedA.e2eRejectedEffectIDs = [firstID]; failedB.e2eRejectedEffectIDs = [firstID]
            let left = flatten(failedA, doc), right = flatten(failedB, doc)
            E2E.record("privacy-failed-prior-\(name)", left.flatMap { x in right.map { x.px == $0.px } } ?? false)
        }
        let clip = CGRect(x: 170, y: 90, width: 40, height: 60)
        if let ctx = Imaging.context(width: imageA.width, height: imageA.height, flipped: true) {
            ctx.scaleBy(x: scale, y: scale); ctx.clip(to: clip)
            rA.drawFrame(ctx); rA.draw(doc, in: ctx, clip: clip)
            let pixels = Geometry.pixelRect(clip, scale: scale)
            let partial = ctx.makeImage().map(E2E.bitmap)
            E2E.record("privacy-dirty-clip-\(name)", partial.map { value in equal(value, fullA) { inside($0, $1, [pixels]) } } ?? false)
        } else { E2E.record("privacy-dirty-clip-\(name)", false) }
        live(doc, id: secondID, image: imageA, scale: scale, name: name, expected: fullA)
        live(doc, id: secondID, image: imageB, scale: scale, name: name + "-changed-secret", expected: fullB)
    }

    private static func live(_ doc: EditorDocument, id: Int, image: CGImage, scale: CGFloat, name: String, expected: E2E.Bitmap) {
        let renderer = Renderer(frame: image, scale: scale)
        let root = PassThroughView(frame: crop)
        root.layerContentsRedrawPolicy = .never
        root.addSubview(FrameView(frame: crop, image: image, smooth: false))
        let committed = AnnotationsView(frame: crop, renderer: renderer), live = LiveMarkView(frame: crop)
        root.addSubview(committed); root.addSubview(live)
        E2E.bindFailures(renderer, committed: committed, live: live)
        let window = OverlayWindow(contentRect: crop, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root; window.orderFrontRegardless()
        defer { live.releaseResources(); renderer.releaseTransientResources(); window.orderOut(nil); window.contentView = nil }
        renderer.liveEffectID = id
        committed.sync(doc, hide: nil, live: id)
        guard let mark = doc.annotations.first(where: { $0.id == id }), let guardRect = renderer.liveGuard(for: mark) else {
            E2E.record("privacy-live-guard-\(name)", false); return
        }
        live.show(mark, renderer: renderer)
        let preview = E2E.snapshotImageLayers(root, scale: scale), area = Geometry.pixelRect(guardRect, scale: scale)
        E2E.record("privacy-live-guard-\(name)", preview.map { value in
            value.frac(area.cgRect) { $0.r == 0 && $0.g == 0 && $0.b == 0 && $0.a == 1 } == 1
        } ?? false)
        committed.sync(doc, hide: nil); committed.displayIfNeeded(); live.show(nil, renderer: renderer)
        let final = E2E.snapshotImageLayers(root, scale: scale)
        E2E.record("privacy-live-commit-\(name)", final?.px == expected.px && renderer.e2eLiveBytes == 0 && live.e2eRetainedPatchBytes == 0)
    }

    private static func overlappingProtections(scale: CGFloat) {
        let first = CGRect(x: 20, y: 20, width: 120, height: 110), second = CGRect(x: 90, y: 45, width: 80, height: 105)
        let third = CGRect(x: 60, y: 90, width: 170, height: 90)
        var doc = EditorDocument()
        add(.blur, first, doc: &doc); add(.pixelate, second, doc: &doc)
        let prior = doc
        add(.blur, third, doc: &doc)
        let areas = [first, second].map { Geometry.pixelRect($0, scale: scale) }
        guard let imageA = source(scale: scale, hidden: [first, second], changed: false),
              let imageB = source(scale: scale, hidden: [first, second], changed: true),
              let fullA = flatten(Renderer(frame: imageA, scale: scale), doc),
              let fullB = flatten(Renderer(frame: imageB, scale: scale), doc),
              let before = flatten(Renderer(frame: imageA, scale: scale), prior) else {
            E2E.record("privacy-overlapping-holes-\(Int(scale))x", false); return
        }
        E2E.record("privacy-overlapping-holes-\(Int(scale))x",
                   equal(fullA, before) { inside($0, $1, areas) } && equal(fullA, fullB) { !inside($0, $1, areas) })
    }

    private static func mutation(scale: CGFloat) {
        guard let image = source(scale: scale, hidden: [], changed: false) else { E2E.record("privacy-mutation-setup", false); return }
        for kind in [ShapeKind.blur, .pixelate, .rectangle] {
            var doc = EditorDocument()
            let first = add(kind, CGRect(x: 20, y: 20, width: 120, height: 110), doc: &doc)
            let second = add(.pixelate, CGRect(x: 90, y: 70, width: 140, height: 105), doc: &doc)
            let renderer = Renderer(frame: image, scale: scale)
            _ = flatten(renderer, doc)
            for operation in ["move", "resize", "delete", "undo", "undo", "undo"] {
                doc.selectedID = first
                switch operation {
                case "move": doc.beginDrag(); doc.move(first, by: Offset(dx: 30, dy: 10)); doc.endDrag()
                case "resize": doc.beginDrag(); doc.resizeFromDragStart(first, handle: .bottomRight, by: Offset(dx: 20, dy: 15)); doc.endDrag()
                case "delete": doc.deleteSelected()
                default: doc.undo()
                }
                let dirty = renderer.synchronize(doc)
                let later = doc.annotations.first { $0.id == second }.flatMap { renderer.redactionBounds($0) }
                let actual = flatten(renderer, doc), fresh = flatten(Renderer(frame: image, scale: scale), doc)
                E2E.record("privacy-cache-\(kind.rawValue)-\(operation)-\(doc.history.undoStates.count)-\(Int(scale))x",
                           actual.flatMap { a in fresh.map { a.px == $0.px } } == true
                           && later.flatMap { r in dirty.map { $0.contains(r) } } == true)
                if operation == "move", let result = fresh {
                    live(doc, id: first, image: image, scale: scale, name: "moved-first-\(kind.rawValue)-\(Int(scale))x", expected: result)
                }
            }
        }
    }

    private static func overlapBudget(scale: CGFloat) {
        guard let image = source(scale: scale, hidden: [], changed: false) else { return }
        var doc = EditorDocument()
        for _ in 0..<65 { add(.rectangle, CGRect(x: 40, y: 40, width: 60, height: 60), doc: &doc) }
        let rect = CGRect(x: 30, y: 30, width: 150, height: 130)
        add(.blur, rect, doc: &doc)
        let renderer = Renderer(frame: image, scale: scale), result = flatten(renderer, doc)
        E2E.record("privacy-overlap-budget-fails-opaque-\(Int(scale))x", result.map { value in
            value.frac(Geometry.pixelRect(rect, scale: scale).cgRect) { $0.r == 0 && $0.g == 0 && $0.b == 0 && $0.a == 1 } == 1
        } ?? false)
    }

    private static func cacheEviction() {
        guard let small = E2E.checker(256, 192) else { E2E.record("privacy-cache-entry-setup", false); return }
        var doc = EditorDocument()
        for index in 0..<130 {
            add(.pixelate, CGRect(x: (index % 16) * 16, y: (index / 16) * 16, width: 14, height: 14), doc: &doc)
        }
        let renderer = Renderer(frame: small, scale: 1)
        let first = flatten(renderer, doc), repeated = flatten(renderer, doc)
        E2E.record("privacy-cache-entry-eviction", renderer.e2eCacheEntryCount == 128 && renderer.e2eCacheBytes <= 64 * 1024 * 1024
                   && first.flatMap { a in repeated.map { a.px == $0.px } } == true,
                   ["retainedBytes": renderer.e2eCacheBytes, "entries": renderer.e2eCacheEntryCount])
        renderer.releaseTransientResources()

        guard let large = E2E.checker(2048, 2048) else { E2E.record("privacy-cache-byte-setup", false); return }
        var largeDoc = EditorDocument()
        for _ in 0..<6 { add(.pixelate, CGRect(x: 0, y: 0, width: 2048, height: 2048), doc: &largeDoc) }
        let bounded = Renderer(frame: large, scale: 1)
        let before = flatten(bounded, largeDoc), after = flatten(bounded, largeDoc)
        E2E.record("privacy-cache-byte-eviction", bounded.e2eCacheBytes <= 64 * 1024 * 1024 && bounded.e2eCacheBytes >= 32 * 1024 * 1024
                   && bounded.e2eCacheEntryCount < 6 && before.flatMap { a in after.map { a.px == $0.px } } == true,
                   ["retainedBytes": bounded.e2eCacheBytes, "entries": bounded.e2eCacheEntryCount])
        bounded.releaseTransientResources()
        E2E.record("privacy-cache-release", bounded.e2eCacheBytes == 0 && bounded.e2eCacheEntryCount == 0 && bounded.e2eLiveBytes == 0)
    }

    private static func dependencyScanBudget() {
        guard let image = E2E.checker(256, 192) else {
            E2E.record("privacy-dependency-scan-setup", false); return
        }
        for count in [1024, 1025] {
            var doc = EditorDocument(styles: [.rectangle: ShapeStyle(color: .black, filled: true)])
            doc.beginDrag()
            for _ in 0..<count {
                let id = doc.addShape(.rectangle, at: CGPoint(x: 4, y: 4))
                doc.extendShape(id, to: CGPoint(x: 8, y: 8))
            }
            doc.endDrag()
            let area = CGRect(x: 100, y: 100, width: 100, height: 70)
            add(.pixelate, area, doc: &doc)
            let renderer = Renderer(frame: image, scale: 1)
            guard let output = flatten(renderer, doc) else {
                E2E.record("privacy-dependency-scan-\(count)", false); continue
            }
            let opaqueBlack = output.frac(area) { $0.r == 0 && $0.g == 0 && $0.b == 0 && $0.a == 1 } == 1
            E2E.record("privacy-dependency-scan-\(count)", opaqueBlack == (count > 1024))
        }
    }

    private static func fractionalOpaqueProtection() {
        let scale = CGFloat(2040) / 1400
        let area = PixelRect(x: 31, y: 29, w: 100, h: 80)
        let points = area.points(scale: scale)
        var doc = EditorDocument()
        add(.rectangle, points, doc: &doc)
        let before = doc
        add(.pixelate, PixelRect(x: 20, y: 60, w: 210, h: 120).points(scale: scale), doc: &doc)
        guard let imageA = source(scale: scale, hidden: [points], changed: false),
              let imageB = source(scale: scale, hidden: [points], changed: true),
              let mask = Imaging.context(width: imageA.width, height: imageA.height, flipped: true) else {
            E2E.record("privacy-fractional-opaque-setup", false); return
        }
        mask.scaleBy(x: scale, y: scale)
        Renderer(frame: imageA, scale: scale).draw(before, in: mask)
        guard let maskPixels = mask.makeImage().map(E2E.bitmap),
              let prior = flatten(Renderer(frame: imageA, scale: scale), before),
              let actual = flatten(Renderer(frame: imageA, scale: scale), doc),
              let changed = flatten(Renderer(frame: imageB, scale: scale), doc) else {
            E2E.record("privacy-fractional-opaque-materialize", false); return
        }
        let opaque = maskPixels.frac(area.cgRect) { $0.r == 0 && $0.g == 0 && $0.b == 0 && $0.a == 1 } == 1
        E2E.record("privacy-fractional-opaque-coverage", opaque)
        E2E.record("privacy-fractional-first-protection", equal(prior, actual) { inside($0, $1, [area]) })
        E2E.record("privacy-fractional-source-noninterference", actual.px == changed.px)
    }

    private static func editorCommit() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        guard let image = E2E.checker(800, 600) else { E2E.record("privacy-editor-setup", false); return }
        let renderer = Renderer(frame: image, scale: 1)
        let view = EditorView(frame: bounds, renderer: renderer, mode: .rectangle, initialCrop: bounds,
                              styles: [.rectangle: ShapeStyle(color: .black, filled: true)],
                              showMagnifier: false, pickRects: [], finishOnPick: false)
        let window = OverlayWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFrontRegardless()
        defer { view.releaseResources(); window.orderOut(nil); window.contentView = nil }
        let surface = (window: window as NSWindow, view: view)
        view.setTool(.shape(.rectangle))
        E2E.mouse(.leftMouseDown, CGPoint(x: 120, y: 160), in: surface)
        E2E.mouse(.leftMouseDragged, CGPoint(x: 360, y: 320), in: surface)
        E2E.mouse(.leftMouseUp, CGPoint(x: 360, y: 320), in: surface)
        view.setTool(.shape(.pixelate))
        E2E.mouse(.leftMouseDown, CGPoint(x: 280, y: 220), in: surface)
        E2E.mouse(.leftMouseDragged, CGPoint(x: 580, y: 440), in: surface)
        let preview = E2E.snapshotImageLayers(view, scale: 1)
        let liveArea = CGRect(x: 280, y: 220, width: 300, height: 220)
        E2E.record("privacy-editor-drag-guard", preview.map {
            $0.frac(liveArea) { $0.r == 0 && $0.g == 0 && $0.b == 0 && $0.a == 1 } == 1
        } ?? false)
        E2E.mouse(.leftMouseUp, CGPoint(x: 580, y: 440), in: surface)
        let committed = E2E.snapshotImageLayers(view, scale: 1, display: false)
        let exported = Export.flatten(renderer: renderer, doc: view.doc, crop: bounds, lasso: nil).map(E2E.bitmap)
        E2E.record("privacy-editor-commit-export", view.doc.annotations.count == 2
                   && committed.flatMap { actual in exported.map { actual.px == $0.px } } == true
                   && renderer.e2eLiveBytes == 0 && view.e2eLiveLayerBytes == 0)
    }

    private static func allocationRefusal() {
        let limit = Imaging.maximumPixels
        E2E.record("privacy-allocation-boundaries", Imaging.allocationBytes(width: Int.max, height: 2) == nil
                   && Imaging.allocationBytes(width: Int.max / 2, height: 1) == nil
                   && Imaging.allocationBytes(width: limit + 1, height: 1) == nil
                   && Imaging.allocationBytes(width: 8192, height: 8193) == nil
                   && Imaging.allocationBytes(width: 8192, height: 8192) == limit * 4
                   && Imaging.context(width: limit + 1, height: 1, flipped: true) == nil
                   && Imaging.pixelDimensions(size: CGSize(width: CGFloat.infinity, height: 1), scale: 1) == nil
                   && Imaging.pixelDimensions(size: CGSize(width: 1, height: 1), scale: CGFloat.nan) == nil)
        guard let image = E2E.checker(32, 32) else { E2E.record("privacy-decoration-refusal", false); return }
        var options = CaptureOptions()
        options.shadow = true
        E2E.record("privacy-decoration-refusal", Export.decorate(image, options: options, scale: CGFloat(limit)) == nil
                   && Export.encode(nil, scale: 1) == nil)
    }
}
#endif
