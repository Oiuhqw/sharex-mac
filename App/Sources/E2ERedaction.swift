#if SHAREX_E2E
import AppKit
import ShareXCore

@MainActor
enum E2ERedaction {
    private static let size = CGSize(width: 320, height: 240)

    private static func matchesMask(_ image: E2E.Bitmap, baseline: E2E.Bitmap, area: PixelRect?) -> Bool {
        guard image.w == baseline.w, image.h == baseline.h else { return false }
        for y in 0..<image.h { for x in 0..<image.w {
            let i = (y * image.w + x) * 4
            let covered = area.map { x >= $0.x && x < $0.x + $0.w && y >= $0.y && y < $0.y + $0.h } ?? false
            if covered {
                if image.px[i] != 0 || image.px[i + 1] != 0 || image.px[i + 2] != 0 || image.px[i + 3] != 255 { return false }
            } else if image.px[i..<(i + 4)] != baseline.px[i..<(i + 4)] { return false }
        } }
        return true
    }

    private static func snapshot(_ view: NSView, scale: CGFloat, name: String? = nil) -> E2E.Bitmap? {
        view.window?.displayIfNeeded()
        CATransaction.flush()
        guard let layer = view.layer,
              let ctx = Imaging.context(width: Int(size.width * scale), height: Int(size.height * scale), flipped: true) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let image = ctx.makeImage() else { return nil }
        if let name { E2EOrientation.writePNG(image, name) }
        return E2E.bitmap(image)
    }

    private static func effectRestored(_ image: E2E.Bitmap, baseline: E2E.Bitmap, area: PixelRect) -> Bool {
        guard image.w == baseline.w, image.h == baseline.h else { return false }
        var hasColor = false, changed = false
        for y in 0..<image.h { for x in 0..<image.w {
            let i = (y * image.w + x) * 4
            let same = image.px[i..<(i + 4)] == baseline.px[i..<(i + 4)]
            if x >= area.x && x < area.x + area.w && y >= area.y && y < area.y + area.h {
                hasColor = hasColor || image.px[i] > 0 || image.px[i + 1] > 0 || image.px[i + 2] > 0
                changed = changed || !same
                if image.px[i + 3] != 255 { return false }
            } else if !same { return false }
        } }
        return hasColor && changed
    }

    private static func differences(_ actual: E2E.Bitmap?, expected: E2E.Bitmap?, mask: PixelRect? = nil) -> [String: Any] {
        guard let actual, let expected, actual.w == expected.w, actual.h == expected.h else { return ["missingOrWrongSize": true] }
        var count = 0, bounds = CGRect.null
        var first: [String: Any] = [:]
        for y in 0..<actual.h { for x in 0..<actual.w {
            let i = (y * actual.w + x) * 4
            let covered = mask.map { x >= $0.x && x < $0.x + $0.w && y >= $0.y && y < $0.y + $0.h } ?? false
            let wanted = covered ? [UInt8(0), 0, 0, 255] : Array(expected.px[i..<(i + 4)])
            if actual.px[i..<(i + 4)].elementsEqual(wanted) { continue }
            count += 1; bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
            if first.isEmpty { first = ["xy": [x, y], "actual": Array(actual.px[i..<(i + 4)]), "expected": wanted] }
        } }
        return ["pixels": count, "bounds": bounds.isNull ? [] : [bounds.minX, bounds.minY, bounds.width, bounds.height], "first": first]
    }

    static func run() async {
        let regions: [(String, CGPoint, CGPoint)] = [
            ("fractional", CGPoint(x: 20.25, y: 20.25), CGPoint(x: 140.75, y: 100.75)),
            ("clipped", CGPoint(x: -10.25, y: 20.25), CGPoint(x: 50.75, y: 100.75)),
            ("off-frame", CGPoint(x: -60.25, y: 20.25), CGPoint(x: -10.75, y: 100.75))
        ]
        for scale in [CGFloat(1), CGFloat(2)] {
            guard let image = E2E.checker(Int(size.width * scale), Int(size.height * scale)) else {
                E2E.record("redaction-failure-setup", false); return
            }
            for kind in [ShapeKind.blur, .pixelate] {
                for (region, start, end) in regions {
                    let name = "\(kind.rawValue)-\(region)-\(Int(scale))x"
                    var style = ShapeStyle.defaults(for: kind)
                    style.opacity = 0.1
                    var doc = EditorDocument(styles: [kind: style])
                    let id = doc.addShape(kind, at: start)
                    doc.extendShape(id, to: end)
                    guard let mark = doc.selected else { E2E.record("redaction-failure-\(name)", false); continue }
                    let area = Geometry.pixelRect(mark.rect, scale: scale).clamped(width: image.width, height: image.height)
                    let renderer = Renderer(frame: image, scale: scale)
                    renderer.e2eRejectEffectImage = true
                    guard let base = Export.flatten(renderer: renderer, doc: EditorDocument(), crop: CGRect(origin: .zero, size: size), lasso: nil),
                          let flat = Export.flatten(renderer: renderer, doc: doc, crop: CGRect(origin: .zero, size: size), lasso: nil),
                          let encoded = Export.encode(flat, scale: scale),
                          Export.write(encoded),
                          let pngData = NSPasteboard.general.data(forType: .png), let tiffData = NSPasteboard.general.data(forType: .tiff),
                          pngData == encoded.png, tiffData == encoded.tiff,
                          let png = E2E.decode(pngData), let tiff = E2E.decode(tiffData) else {
                        E2E.record("redaction-failure-export-\(name)", false, ["error": "flatten, encode or clipboard failed"]); continue
                    }
                    let baseline = E2E.bitmap(base)
                    let pngBitmap = E2E.bitmap(png), tiffBitmap = E2E.bitmap(tiff)
                    E2E.record("redaction-failure-export-\(name)",
                               matchesMask(E2E.bitmap(flat), baseline: baseline, area: area)
                               && matchesMask(pngBitmap, baseline: baseline, area: area)
                               && matchesMask(tiffBitmap, baseline: baseline, area: area)
                               && pngBitmap.px == tiffBitmap.px,
                               ["faultInjected": true, "coverage": area.map { [$0.x, $0.y, $0.w, $0.h] } ?? []])

                    let root = PassThroughView(frame: CGRect(origin: .zero, size: size))
                    root.layerContentsRedrawPolicy = .never
                    root.addSubview(FrameView(frame: root.bounds, image: image, smooth: false))
                    let live = LiveMarkView(frame: root.bounds)
                    root.addSubview(live)
                    let window = OverlayWindow(contentRect: root.bounds, styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = root
                    window.orderFrontRegardless()
                    let previewBase = snapshot(root, scale: scale)
                    renderer.liveEffectID = id
                    live.show(mark, renderer: renderer)
                    let failedPreview = snapshot(root, scale: scale)
                    let previewOK = previewBase.flatMap { baseline in
                        failedPreview.map { matchesMask($0, baseline: baseline, area: area) }
                    } ?? false
                    E2E.record("redaction-failure-live-\(name)", previewOK, ["source": "CoreAnimation layer render", "faultInjected": true])

                    renderer.e2eRejectEffectImage = false
                    live.show(mark, renderer: renderer)
                    let recoveredPreview = snapshot(root, scale: scale)
                    var recovered = false
                    if let previewBase, let recoveredPreview {
                        if let area {
                            recovered = renderer.livePatch(mark) != nil
                                && effectRestored(recoveredPreview, baseline: previewBase, area: area)
                            if let recoveredFlat = Export.flatten(renderer: renderer, doc: doc, crop: CGRect(origin: .zero, size: size), lasso: nil) {
                                recovered = recovered && effectRestored(E2E.bitmap(recoveredFlat), baseline: baseline, area: area)
                            } else { recovered = false }
                        } else { recovered = recoveredPreview.px == previewBase.px }
                    }
                    E2E.record("redaction-failure-recovery-\(name)", recovered)
                    window.orderOut(nil); window.contentView = nil
                }
            }
            overlappingEffects(image: image, scale: scale)
            await movingFailedEffect(image: image, scale: scale)
            await partialRedrawRecovery(image: image, scale: scale)
        }
    }

    private static func overlappingEffects(image: CGImage, scale: CGFloat) {
        for firstKind in [ShapeKind.blur, .pixelate] {
            let secondKind: ShapeKind = firstKind == .blur ? .pixelate : .blur
            let name = "\(firstKind.rawValue)-then-\(secondKind.rawValue)-\(Int(scale))x"
            var doc = EditorDocument()
            let first = doc.addShape(firstKind, at: CGPoint(x: 20, y: 20))
            doc.extendShape(first, to: CGPoint(x: 180, y: 140))
            let second = doc.addShape(secondKind, at: CGPoint(x: 100, y: 70))
            doc.extendShape(second, to: CGPoint(x: 230, y: 190))
            guard let firstMark = doc.annotations.first, let liveMark = doc.selected,
                  let area = Geometry.pixelRect(firstMark.rect, scale: scale).clamped(width: image.width, height: image.height) else {
                E2E.record("redaction-overlap-\(name)", false); continue
            }
            var laterOnly = doc
            laterOnly.selectedID = first; laterOnly.deleteSelected()
            let renderer = Renderer(frame: image, scale: scale)
            renderer.e2eRejectedEffectIDs = [first]
            guard let base = Export.flatten(renderer: Renderer(frame: image, scale: scale), doc: laterOnly,
                                            crop: CGRect(origin: .zero, size: size), lasso: nil),
                  let flat = Export.flatten(renderer: renderer, doc: doc, crop: CGRect(origin: .zero, size: size), lasso: nil),
                  renderer.livePatch(liveMark) != nil, renderer.redactionFailureRects.count == 1,
                  let encoded = Export.encode(flat, scale: scale), Export.write(encoded),
                  let pngData = NSPasteboard.general.data(forType: .png), let tiffData = NSPasteboard.general.data(forType: .tiff),
                  pngData == encoded.png, tiffData == encoded.tiff,
                  let png = E2E.decode(pngData), let tiff = E2E.decode(tiffData) else {
                E2E.record("redaction-overlap-export-\(name)", false); continue
            }
            let baseline = E2E.bitmap(base)
            E2E.record("redaction-overlap-export-\(name)",
                       matchesMask(E2E.bitmap(png), baseline: baseline, area: area)
                       && matchesMask(E2E.bitmap(tiff), baseline: baseline, area: area),
                       ["failedEffect": first, "successfulEffect": second])

            // The successful later effect is live above the committed failed effect.
            let previewRenderer = Renderer(frame: image, scale: scale)
            previewRenderer.e2eRejectedEffectIDs = [first]
            let root = PassThroughView(frame: CGRect(origin: .zero, size: size))
            root.layerContentsRedrawPolicy = .never
            root.addSubview(FrameView(frame: root.bounds, image: image, smooth: false))
            let committed = AnnotationsView(frame: root.bounds, renderer: previewRenderer)
            root.addSubview(committed)
            let live = LiveMarkView(frame: root.bounds)
            root.addSubview(live)
            let window = OverlayWindow(contentRect: root.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = root; window.orderFrontRegardless()
            previewRenderer.liveEffectID = second
            committed.sync(doc, hide: nil, live: second)
            live.show(liveMark, renderer: previewRenderer)
            let preview = snapshot(root, scale: scale)
            let covered = preview.map { image in
                image.frac(area.cgRect) { $0.r == 0 && $0.g == 0 && $0.b == 0 && $0.a == 1 } == 1
            } ?? false
            E2E.record("redaction-overlap-live-\(name)", covered && previewRenderer.livePatch(liveMark) != nil,
                       ["source": "CoreAnimation layer render"])

            doc.selectedID = first; doc.deleteSelected()
            committed.sync(doc, hide: nil, live: second)
            live.show(liveMark, renderer: previewRenderer)
            _ = snapshot(root, scale: scale)
            E2E.record("redaction-overlap-delete-clears-mask-\(name)", previewRenderer.redactionFailureRects.isEmpty)
            window.orderOut(nil); window.contentView = nil
        }
    }

    private static func movingFailedEffect(image: CGImage, scale: CGFloat) async {
        for kind in [ShapeKind.blur, .pixelate] {
            let name = "\(kind.rawValue)-\(Int(scale))x"
            var doc = EditorDocument()
            let id = doc.addShape(kind, at: CGPoint(x: 20, y: 20))
            doc.extendShape(id, to: CGPoint(x: 100, y: 90))
            let renderer = Renderer(frame: image, scale: scale)
            renderer.e2eRejectEffectImage = true
            let root = PassThroughView(frame: CGRect(origin: .zero, size: size))
            root.layerContentsRedrawPolicy = .never
            root.addSubview(FrameView(frame: root.bounds, image: image, smooth: false))
            let committed = AnnotationsView(frame: root.bounds, renderer: renderer)
            root.addSubview(committed)
            let live = LiveMarkView(frame: root.bounds)
            root.addSubview(live)
            let window = OverlayWindow(contentRect: root.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = root; window.orderFrontRegardless()
            let baseline = snapshot(root, scale: scale, name: "redaction-move-\(name)-baseline.png")
            committed.sync(doc, hide: nil)
            live.show(nil, renderer: renderer)
            _ = snapshot(root, scale: scale, name: "redaction-move-\(name)-committed.png")
            renderer.liveEffectID = id
            committed.sync(doc, hide: nil, live: id)
            live.show(doc.selected, renderer: renderer)
            _ = snapshot(root, scale: scale, name: "redaction-move-\(name)-drag-start.png")

            doc.move(id, by: Offset(dx: 130, dy: 100))
            committed.sync(doc, hide: nil, live: id)
            live.show(doc.selected, renderer: renderer)
            let moved = snapshot(root, scale: scale, name: "redaction-move-\(name)-moved-immediate.png")
            let area = doc.selected.flatMap {
                Geometry.pixelRect($0.rect, scale: scale).clamped(width: image.width, height: image.height)
            }
            let moveOK = baseline.flatMap { base in moved.map { matchesMask($0, baseline: base, area: area) } } ?? false
            await E2E.wait(20)
            let movedSettled = snapshot(root, scale: scale, name: "redaction-move-\(name)-moved-settled.png")
            E2E.record("redaction-failed-move-clears-old-\(name)", moveOK && area != nil,
                       ["immediate": differences(moved, expected: baseline, mask: area),
                        "settled": differences(movedSettled, expected: baseline, mask: area),
                        "failureRects": renderer.redactionFailureRects.map { [$0.minX, $0.minY, $0.width, $0.height] }])

            renderer.e2eRejectEffectImage = false
            live.show(doc.selected, renderer: renderer)
            let recovered = snapshot(root, scale: scale, name: "redaction-move-\(name)-recovered-immediate.png")
            let flat = Export.flatten(renderer: renderer, doc: doc, crop: CGRect(origin: .zero, size: size), lasso: nil)
            if let flat { E2EOrientation.writePNG(flat, "redaction-move-\(name)-export.png") }
            await E2E.wait(20)
            let recoveredSettled = snapshot(root, scale: scale, name: "redaction-move-\(name)-recovered-settled.png")
            let recoveryOK: Bool
            if let recovered, let flat, let baseline, let area {
                recoveryOK = renderer.redactionFailureRects.isEmpty
                    && effectRestored(recovered, baseline: baseline, area: area)
                    && recovered.px == E2E.bitmap(flat).px
            } else { recoveryOK = false }
            E2E.record("redaction-failed-move-recovery-\(name)", recoveryOK,
                       ["immediateVsExport": differences(recovered, expected: flat.map(E2E.bitmap)),
                        "settledVsExport": differences(recoveredSettled, expected: flat.map(E2E.bitmap)),
                        "failureRects": renderer.redactionFailureRects.map { [$0.minX, $0.minY, $0.width, $0.height] }])
            window.orderOut(nil); window.contentView = nil
        }
    }

    private static func partialRedrawRecovery(image: CGImage, scale: CGFloat) async {
        for kind in [ShapeKind.blur, .pixelate] {
            let name = "\(kind.rawValue)-\(Int(scale))x"
            var doc = EditorDocument()
            let id = doc.addShape(kind, at: CGPoint(x: 20, y: 20))
            doc.extendShape(id, to: CGPoint(x: 220, y: 180))
            let renderer = Renderer(frame: image, scale: scale)
            renderer.e2eRejectedEffectIDs = [id]
            func scene(_ renderer: Renderer) -> (root: PassThroughView, committed: AnnotationsView, live: LiveMarkView, window: NSWindow) {
                let root = PassThroughView(frame: CGRect(origin: .zero, size: size))
                root.layerContentsRedrawPolicy = .never
                root.addSubview(FrameView(frame: root.bounds, image: image, smooth: false))
                let committed = AnnotationsView(frame: root.bounds, renderer: renderer)
                root.addSubview(committed)
                let live = LiveMarkView(frame: root.bounds); root.addSubview(live)
                let window = OverlayWindow(contentRect: root.bounds, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = root; window.orderFrontRegardless()
                return (root, committed, live, window)
            }
            let current = scene(renderer)
            current.committed.sync(doc, hide: nil); current.live.show(nil, renderer: renderer)
            _ = snapshot(current.root, scale: scale)
            await E2E.wait(20)
            _ = snapshot(current.root, scale: scale)

            renderer.e2eRejectedEffectIDs = []
            let small = doc.addShape(.rectangle, at: CGPoint(x: 60, y: 70))
            doc.extendShape(small, to: CGPoint(x: 80, y: 90))
            current.committed.sync(doc, hide: nil)
            _ = snapshot(current.root, scale: scale)
            await E2E.wait(20)
            let recovered = snapshot(current.root, scale: scale)

            let freshRenderer = Renderer(frame: image, scale: scale)
            let reference = scene(freshRenderer)
            reference.committed.sync(doc, hide: nil); reference.live.show(nil, renderer: freshRenderer)
            let expected = snapshot(reference.root, scale: scale)
            let same = recovered.flatMap { actual in expected.map { actual.px == $0.px } } ?? false
            E2E.record("redaction-partial-redraw-recovery-\(name)", same && renderer.redactionFailureRects.isEmpty)
            current.window.orderOut(nil); current.window.contentView = nil
            reference.window.orderOut(nil); reference.window.contentView = nil

            // A new document can reuse an old effect ID for a normal shape.
            let reused = Renderer(frame: image, scale: scale)
            reused.e2eRejectedEffectIDs = [id]
            var firstOnly = EditorDocument()
            let failedID = firstOnly.addShape(kind, at: CGPoint(x: 20, y: 20))
            firstOnly.extendShape(failedID, to: CGPoint(x: 220, y: 180))
            _ = Export.flatten(renderer: reused, doc: firstOnly, crop: CGRect(origin: .zero, size: size), lasso: nil)
            var reset = EditorDocument()
            let replacement = reset.addShape(.rectangle, at: CGPoint(x: 20, y: 20))
            reset.extendShape(replacement, to: CGPoint(x: 220, y: 180))
            let afterReset = Export.flatten(renderer: reused, doc: reset, crop: CGRect(origin: .zero, size: size), lasso: nil)
            let resetReference = Export.flatten(renderer: Renderer(frame: image, scale: scale), doc: reset,
                                                crop: CGRect(origin: .zero, size: size), lasso: nil)
            let resetMatches = afterReset.flatMap { actual in resetReference.map { E2E.bitmap(actual).px == E2E.bitmap($0).px } } ?? false
            E2E.record("redaction-reset-id-clears-mask-\(name)", failedID == replacement && reused.redactionFailureRects.isEmpty && resetMatches)
        }
    }
}
#endif
