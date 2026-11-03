#if SHAREX_E2E
import AppKit
import ShareXCore

@MainActor
enum E2ERenderer {
    private struct Variant {
        let name: String
        var hide: Int? = nil
        var skip: Int? = nil
        var clip: CGRect? = nil
    }

    @discardableResult
    private static func add(_ kind: ShapeKind, at p: CGPoint, to q: CGPoint, doc: inout EditorDocument) -> Int {
        doc.beginDrag()
        let id = doc.addShape(kind, at: p)
        doc.extendShape(id, to: q)
        doc.endDrag()
        return id
    }

    private static func pixels(_ ctx: CGContext) -> Data? {
        guard let p = ctx.data else { return nil }
        // Ignore any row padding, whose bytes are not part of the rendered image.
        var bytes = Data(capacity: ctx.width * ctx.height * 4)
        for y in 0..<ctx.height { bytes.append(p.advanced(by: y * ctx.bytesPerRow).assumingMemoryBound(to: UInt8.self), count: ctx.width * 4) }
        return bytes
    }

    private static func render(_ doc: EditorDocument, renderer: Renderer, context: CGContext, legacy: Bool,
                               variant: Variant = Variant(name: "full")) {
        context.saveGState()
        if let clip = variant.clip { context.clip(to: clip) }
        if legacy { renderer.e2eDrawLegacy(doc, in: context, hide: variant.hide, skip: variant.skip, clip: variant.clip) }
        else { renderer.draw(doc, in: context, hide: variant.hide, skip: variant.skip, clip: variant.clip) }
        context.restoreGState()
    }

    private static func equivalent(_ doc: EditorDocument, image: CGImage, scale: CGFloat, variant: Variant) -> Bool {
        guard let old = Imaging.context(width: image.width, height: image.height, flipped: true),
              let new = Imaging.context(width: image.width, height: image.height, flipped: true) else { return false }
        old.scaleBy(x: scale, y: scale); new.scaleBy(x: scale, y: scale)
        let a = Renderer(frame: image, scale: scale), b = Renderer(frame: image, scale: scale)
        a.drawFrame(old); b.drawFrame(new)
        render(doc, renderer: a, context: old, legacy: true, variant: variant)
        render(doc, renderer: b, context: new, legacy: false, variant: variant)
        guard let x = pixels(old), let y = pixels(new) else { return false }
        return x == y
    }

    static func run() {
        for scale in [CGFloat(1), CGFloat(2)] {
            guard let image = E2E.checker(Int(320 * scale), Int(240 * scale)) else {
                E2E.record("renderer-equivalence-setup", false); return
            }
            var doc = EditorDocument()
            let first = add(.step, at: CGPoint(x: 45, y: 45), to: CGPoint(x: 45, y: 45), doc: &doc)
            _ = add(.rectangle, at: CGPoint(x: 20, y: 100), to: CGPoint(x: 95, y: 180), doc: &doc)
            let second = add(.step, at: CGPoint(x: 150, y: 45), to: CGPoint(x: 150, y: 45), doc: &doc)
            _ = add(.arrow, at: CGPoint(x: 120, y: 160), to: CGPoint(x: 200, y: 110), doc: &doc)
            let third = add(.step, at: CGPoint(x: 255, y: 45), to: CGPoint(x: 255, y: 45), doc: &doc)
            let clip = CGRect(x: 110, y: 15, width: 180, height: 155)
            let variants = [
                Variant(name: "mixed"),
                Variant(name: "hide-first-step", hide: first),
                Variant(name: "skip-first-step", skip: first),
                Variant(name: "hide-and-skip", hide: first, skip: second),
                Variant(name: "clip", clip: clip),
                Variant(name: "clip-and-hide", hide: second, clip: clip),
                Variant(name: "clip-and-skip", skip: third, clip: clip)
            ]
            for v in variants {
                E2E.record("renderer-step-\(v.name)-\(Int(scale))x",
                           equivalent(doc, image: image, scale: scale, variant: v))
            }
            doc.selectedID = first; doc.deleteSelected()
            E2E.record("renderer-step-delete-\(Int(scale))x",
                       equivalent(doc, image: image, scale: scale, variant: Variant(name: "delete")))
            doc.undo()
            E2E.record("renderer-step-undo-\(Int(scale))x",
                       equivalent(doc, image: image, scale: scale, variant: Variant(name: "undo")))
            doc.redo()
            E2E.record("renderer-step-redo-\(Int(scale))x",
                       equivalent(doc, image: image, scale: scale, variant: Variant(name: "redo")))
            E2E.record("renderer-empty-\(Int(scale))x",
                       equivalent(EditorDocument(), image: image, scale: scale, variant: Variant(name: "empty")))
        }
    }

    /// Paired annotation-raster CPU/wall timings, not display presentation or total clipboard latency.
    /// Both sides render every mark through the same production primitives and must produce identical pixels.
    static func benchmark(image: CGImage, scale: CGFloat) {
        let cases: [(count: Int, steps: Bool)] = [(10, false), (100, false), (1000, false), (10, true), (100, true), (1000, true)]
        var results: [[String: Any]] = []
        for c in cases {
            var doc = EditorDocument()
            for i in 0..<c.count {
                let p = CGPoint(x: CGFloat(30 + (i % 40) * 40), y: CGFloat(30 + (i / 40) * 40))
                let q = CGPoint(x: p.x + 25, y: p.y + 25)
                let id = doc.addShape(c.steps && i % 10 == 0 ? .step : .rectangle, at: p)
                doc.extendShape(id, to: q)
            }
            let name = "\(c.count)-\(c.steps ? "mixed" : "rectangles")"
            guard let old = Imaging.context(width: image.width, height: image.height, flipped: true),
                  let new = Imaging.context(width: image.width, height: image.height, flipped: true) else {
                E2E.record("renderer-benchmark-\(name)", false, ["error": "context allocation"]); continue
            }
            old.scaleBy(x: scale, y: scale); new.scaleBy(x: scale, y: scale)
            let a = Renderer(frame: image, scale: scale), b = Renderer(frame: image, scale: scale)
            var legacyCPU: [Double] = [], optimizedCPU: [Double] = [], legacyWall: [Double] = [], optimizedWall: [Double] = []
            var pairs: [[String: Any]] = []
            var correct = true
            func one(_ legacy: Bool) -> (cpu: Double, wall: Double) {
                let ctx = legacy ? old : new, renderer = legacy ? a : b
                renderer.drawFrame(ctx)
                let cpu = E2EPerf.cpuNow(), wall = Perf.now()
                render(doc, renderer: renderer, context: ctx, legacy: legacy)
                return (E2EPerf.cpuNow() - cpu, Perf.now() - wall)
            }
            for _ in 0..<2 { _ = one(true); _ = one(false) }
            for i in 0..<12 {
                let legacyFirst = i % 2 == 0
                let first = one(legacyFirst), second = one(!legacyFirst)
                let before = legacyFirst ? first : second, after = legacyFirst ? second : first
                legacyCPU.append(before.cpu); optimizedCPU.append(after.cpu)
                legacyWall.append(before.wall); optimizedWall.append(after.wall)
                if let x = pixels(old), let y = pixels(new) { correct = correct && x == y } else { correct = false }
                pairs.append(["legacyFirst": legacyFirst, "legacyCPU_ms": before.cpu, "optimizedCPU_ms": after.cpu,
                              "legacyWall_ms": before.wall, "optimizedWall_ms": after.wall])
            }
            correct = correct && doc.annotations.count == c.count
                && [legacyCPU, optimizedCPU, legacyWall, optimizedWall].allSatisfy { $0.count == 12 && $0.allSatisfy { $0.isFinite && $0 > 0 } }
            E2E.record("renderer-benchmark-\(name)", correct, ["annotations": c.count, "pairs": pairs.count])
            results.append(["case": name, "annotations": c.count, "pixelEquivalent": correct, "pairs": pairs,
                            "legacyCPU_ms": E2EPerf.stats(legacyCPU), "optimizedCPU_ms": E2EPerf.stats(optimizedCPU),
                            "legacyWall_ms": E2EPerf.stats(legacyWall), "optimizedWall_ms": E2EPerf.stats(optimizedWall)])
        }
        E2EPerf.out["annotationRenderPaired"] = results
    }
}
#endif
