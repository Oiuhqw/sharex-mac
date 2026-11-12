#if SHAREX_E2E
import AppKit
import ShareXCore

@MainActor
enum E2ESmartErase {
    private static let size = CGSize(width: 256, height: 192)
    private static let area = CGRect(x: 80, y: 70, width: 100, height: 60)

    private static func fixture(scale: CGFloat = 1, gradient: Int = 0, mark: CGRect? = nil,
                                changes: [CGRect] = [], transparent: Bool = false, texture: Bool = false,
                                size: CGSize = E2ESmartErase.size) -> CGImage? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            let u = (Double(x) + 0.5) / Double(width), v = (Double(y) + 0.5) / Double(height)
            let shift = gradient == 0 ? 0 : 0.16 * u + (gradient == 2 ? 0.12 * v : 0)
            bytes[i] = UInt8(((0.72 + shift) * 255).rounded())
            bytes[i + 1] = UInt8(((0.68 + shift / 2) * 255).rounded())
            bytes[i + 2] = UInt8(((0.62 - shift / 3) * 255).rounded())
            if texture {
                bytes[i] = UInt8((x * 31 + y * 73) % 256)
                bytes[i + 1] = UInt8((x * 67 + y * 17) % 256)
                bytes[i + 2] = UInt8((x * 11 + y * 41) % 256)
            }
            let point = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
            if changes.contains(where: { $0.contains(point) }) { bytes[i] = 255; bytes[i + 1] = 0; bytes[i + 2] = 180 }
            if transparent { bytes[i] = 0; bytes[i + 1] = 0; bytes[i + 2] = 0; bytes[i + 3] = 0 }
        } }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: Imaging.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        guard let mark else { return image }
        guard let context = Imaging.context(width: width, height: height, flipped: true) else { return nil }
        Imaging.drawUpright(image, in: CGRect(x: 0, y: 0, width: width, height: height), ctx: context)
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(gray: 0.05, alpha: 1))
        context.fill(mark.insetBy(dx: 12, dy: 18))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSAttributedString(string: "Private 2841", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
            .draw(at: CGPoint(x: mark.minX + 3, y: mark.minY + 2))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    @discardableResult
    private static func add(_ kind: ShapeKind, _ rect: CGRect, to doc: inout EditorDocument) -> Int {
        if kind == .rectangle { doc.styles[kind] = ShapeStyle(color: .black, filled: true) }
        doc.beginDrag()
        let id = doc.addShape(kind, at: rect.origin)
        doc.extendShape(id, to: CGPoint(x: rect.maxX, y: rect.maxY))
        doc.endDrag()
        return id
    }

    private static func flatten(_ renderer: Renderer, _ doc: EditorDocument) -> E2E.Bitmap? {
        Export.flatten(renderer: renderer, doc: doc, crop: renderer.source.bounds, lasso: nil).map(E2E.bitmap)
    }

    private static func difference(_ a: E2E.Bitmap, _ b: E2E.Bitmap, inside area: PixelRect? = nil,
                                   excluding: [PixelRect] = []) -> Int {
        guard a.w == b.w, a.h == b.h else { return 255 }
        let bounds = area ?? PixelRect(x: 0, y: 0, w: a.w, h: a.h)
        var maximum = 0
        for y in bounds.y..<bounds.maxY { for x in bounds.x..<bounds.maxX {
            guard !excluding.contains(where: { x >= $0.x && x < $0.maxX && y >= $0.y && y < $0.maxY }) else { continue }
            let i = (y * a.w + x) * 4
            for c in 0..<4 { maximum = max(maximum, abs(Int(a.px[i + c]) - Int(b.px[i + c]))) }
        } }
        return maximum
    }

    private static func black(_ bitmap: E2E.Bitmap, _ rect: CGRect) -> Bool {
        bitmap.frac(rect) { $0.r == 0 && $0.g == 0 && $0.b == 0 && $0.a == 1 } == 1
    }

    static func run() async {
        for scale in [CGFloat(1), CGFloat(2)] {
            quality(scale: scale)
            privacy(scale: scale)
            mutation(scale: scale)
            failure(scale: scale)
        }
        gaps()
        cacheLimits()
        await nativeEditor()
    }

    private static func quality(scale: CGFloat) {
        let rectangles = [area, CGRect(x: 0, y: 65, width: 90, height: 60), CGRect(x: 80, y: 0, width: 100, height: 60),
                          CGRect(x: 166, y: 132, width: 90, height: 60)]
        for gradient in 0...2 { for (index, rect) in rectangles.enumerated() {
            let name = "smart-erase-quality-\(gradient)-edge\(index)-\(Int(scale))x"
            guard let original = fixture(scale: scale, gradient: gradient, mark: rect),
                  let clean = fixture(scale: scale, gradient: gradient) else { E2E.record(name, false); continue }
            var doc = EditorDocument()
            add(.smartErase, rect, to: &doc)
            let renderer = Renderer(frame: original, scale: scale)
            guard let image = Export.flatten(renderer: renderer, doc: doc, crop: renderer.source.bounds, lasso: nil),
                  let encoded = Export.encode(image, scale: scale), let png = E2E.decode(encoded.png),
                  let tiff = E2E.decode(encoded.tiff) else { E2E.record(name, false); continue }
            let actual = E2E.bitmap(image), pixels = Geometry.pixelRect(rect, scale: scale)
            let error = difference(actual, E2E.bitmap(clean), inside: pixels)
            let unchanged = difference(actual, E2E.bitmap(original), excluding: [pixels]) == 0
            E2E.record(name, error <= 4 && unchanged && renderer.smartEraseFailureRects.isEmpty
                       && actual.px == E2E.bitmap(png).px && actual.px == E2E.bitmap(tiff).px,
                       ["maximumChannelError": error, "outsideUnchanged": unchanged, "sourcePixelsRemoved": pixels.w * pixels.h])
            if index == 0 { preview(original, doc: doc, scale: scale, expected: actual, name: name) }
            if gradient == 2 && index == 0 && scale == 1,
               let panel = Imaging.context(width: original.width * 2, height: original.height, flipped: true) {
                Imaging.drawUpright(original, in: CGRect(origin: .zero, size: size), ctx: panel)
                Imaging.drawUpright(image, in: CGRect(x: size.width, y: 0, width: size.width, height: size.height), ctx: panel)
                if let comparison = panel.makeImage() { E2EOrientation.writePNG(comparison, "smart-erase.png") }
            }
        } }
    }

    private static func preview(_ source: CGImage, doc: EditorDocument, scale: CGFloat, expected: E2E.Bitmap, name: String) {
        let renderer = Renderer(frame: source, scale: scale)
        let root = PassThroughView(frame: renderer.source.bounds)
        root.layerContentsRedrawPolicy = .never
        root.addSubview(FrameView(frame: root.bounds, image: source, smooth: false))
        let committed = AnnotationsView(frame: root.bounds, renderer: renderer)
        let live = LiveMarkView(frame: root.bounds)
        root.addSubview(committed); root.addSubview(live)
        let window = OverlayWindow(contentRect: root.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root; window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; renderer.releaseTransientResources() }
        renderer.liveEffectID = doc.selectedID
        committed.sync(doc, hide: nil, live: doc.selectedID)
        live.show(doc.selected, renderer: renderer)
        let preview = E2E.snapshotImageLayers(root, scale: scale)
        committed.sync(doc, hide: nil)
        live.show(nil, renderer: renderer)
        let settled = E2E.snapshotImageLayers(root, scale: scale)
        E2E.record("\(name)-live-committed-export", preview.map { difference($0, expected) <= 4 } == true
                   && settled.map { difference($0, expected) <= 4 } == true,
                   ["liveMaximumChannelError": preview.map { difference($0, expected) } ?? 255,
                    "committedMaximumChannelError": settled.map { difference($0, expected) } ?? 255])
    }

    private static func privacy(scale: CGFloat) {
        let protected = CGRect(x: 60, y: 58, width: 45, height: 28)
        for kind in [ShapeKind.rectangle, .blur, .pixelate, .smartErase] { for later in [false, true] {
            let name = "smart-erase-private-halo-\(kind.rawValue)-\(later ? "later" : "prior")-\(Int(scale))x"
            guard let sourceA = fixture(scale: scale, gradient: 2),
                  let sourceB = fixture(scale: scale, gradient: 2, changes: [protected, area]) else { E2E.record(name, false); continue }
            var doc = EditorDocument()
            if !later { add(kind, protected, to: &doc) }
            let eraseID = add(.smartErase, area, to: &doc)
            if later { add(kind, protected, to: &doc) }
            let rendererA = Renderer(frame: sourceA, scale: scale), rendererB = Renderer(frame: sourceB, scale: scale)
            guard let a = flatten(rendererA, doc), let b = flatten(rendererB, doc) else { E2E.record(name, false); continue }
            let pixels = Geometry.pixelRect(area, scale: scale), mask = Geometry.pixelRect(protected, scale: scale)
            let same = difference(a, b, inside: pixels, excluding: [mask]) == 0
            var preserved = later
            if !later, let context = Imaging.context(width: sourceA.width, height: sourceA.height, flipped: true) {
                context.scaleBy(x: scale, y: scale)
                rendererA.drawFrame(context); rendererA.draw(doc, in: context, hide: eraseID)
                preserved = context.makeImage().map { difference(a, E2E.bitmap($0), inside: mask) == 0 } == true
            }
            E2E.record(name, same && preserved && rendererA.smartEraseFailureRects.isEmpty && rendererB.smartEraseFailureRects.isEmpty,
                       ["hiddenSourceChanged": true, "earlierProtectionPreserved": preserved])
        } }
    }

    private static func mutation(scale: CGFloat) {
        guard let source = fixture(scale: scale, gradient: 2) else { E2E.record("smart-erase-mutation-setup", false); return }
        var doc = EditorDocument()
        add(.smartErase, area, to: &doc)
        let neighbor = add(.rectangle, CGRect(x: 100, y: 60, width: 30, height: 8), to: &doc)
        let renderer = Renderer(frame: source, scale: scale)
        _ = flatten(renderer, doc)
        for (index, operation) in ["move", "resize", "opacity", "undo", "undo", "undo", "redo", "redo", "redo"].enumerated() {
            doc.selectedID = neighbor
            switch operation {
            case "move": doc.beginDrag(); doc.move(neighbor, by: Offset(dx: 12, dy: 0)); doc.endDrag()
            case "resize": doc.beginDrag(); doc.resizeFromDragStart(neighbor, handle: .bottomRight, by: Offset(dx: 12, dy: 0)); doc.endDrag()
            case "opacity": doc.applyStyle({ $0.opacity = 0.5 }, to: .rectangle)
            case "undo": doc.undo()
            default: doc.redo()
            }
            let dirty = renderer.synchronize(doc)
            let cached = flatten(renderer, doc), fresh = flatten(Renderer(frame: source, scale: scale), doc)
            E2E.record("smart-erase-halo-cache-\(index)-\(operation)-\(Int(scale))x",
                       dirty?.contains(area) == true && cached.flatMap { c in fresh.map { c.px == $0.px } } == true)
        }
    }

    private static func failure(scale: CGFloat) {
        for mode in ["injected", "texture", "transparent", "no-ring", "protected-ring"] {
            let rect = mode == "no-ring" ? CGRect(origin: .zero, size: size) : area
            guard let source = fixture(scale: scale, mark: mode == "transparent" ? nil : rect,
                                       transparent: mode == "transparent", texture: mode == "texture") else {
                E2E.record("smart-erase-failure-\(mode)", false); continue
            }
            var doc = EditorDocument()
            let id = add(.smartErase, rect, to: &doc)
            if mode == "protected-ring" {
                for band in [CGRect(x: 60, y: 50, width: 140, height: 20), CGRect(x: 60, y: 130, width: 140, height: 20),
                             CGRect(x: 60, y: 70, width: 20, height: 60), CGRect(x: 180, y: 70, width: 20, height: 60)] {
                    add(.rectangle, band, to: &doc)
                }
            }
            let renderer = Renderer(frame: source, scale: scale)
            if mode == "injected" { renderer.e2eRejectedEffectIDs = [id] }
            let pixels = Geometry.pixelRect(rect, scale: scale)
            let output = flatten(renderer, doc)
            let mark = doc.annotations.first!
            E2E.record("smart-erase-failure-\(mode)-\(Int(scale))x", output.map { black($0, pixels.cgRect) } == true
                       && renderer.livePatch(mark) == nil && renderer.smartEraseFailureRects == [pixels.points(scale: scale)]
                       && renderer.sourceIsProtected(pixels.cgRect))
            if mode == "injected" {
                renderer.e2eRejectedEffectIDs = []
                let recovered = flatten(renderer, doc)
                E2E.record("smart-erase-failure-recovery-\(Int(scale))x", recovered.map { !black($0, pixels.cgRect) } == true
                           && renderer.smartEraseFailureRects.isEmpty)
            }
        }
    }

    private static func gaps() {
        let tileSize = CGSize(width: 128, height: 192)
        guard let tile = fixture(size: tileSize), let layout = DesktopLayout(displays: [
            .init(id: 1, frame: CGRect(origin: .zero, size: tileSize), scale: 1),
            .init(id: 2, frame: CGRect(x: 180, y: 0, width: 128, height: 192), scale: 1)
        ]), let source = DesktopImageSource(layout: layout, images: [tile, tile]) else {
            E2E.record("smart-erase-display-gaps", false); return
        }
        for rect in [CGRect(x: 110, y: 70, width: 50, height: 45), CGRect(x: 142, y: 70, width: 16, height: 45)] {
            var doc = EditorDocument()
            add(.smartErase, rect, to: &doc)
            let renderer = Renderer(source: source, scale: 1)
            let result = flatten(renderer, doc)
            let noSafePixels = rect.minX > 128
            E2E.record("smart-erase-display-gap-\(Int(rect.minX))", result.map { black($0, rect) == noSafePixels } == true
                       && renderer.smartEraseFailureRects.isEmpty == !noSafePixels)
        }
    }

    private static func cacheLimits() {
        guard let source = fixture(size: CGSize(width: 1024, height: 768)) else { E2E.record("smart-erase-cache-setup", false); return }
        var doc = EditorDocument()
        for i in 0..<130 { add(.smartErase, CGRect(x: 24 + (i % 16) * 60, y: 24 + (i / 16) * 60, width: 24, height: 24), to: &doc) }
        let renderer = Renderer(frame: source, scale: 1)
        let first = flatten(renderer, doc), again = flatten(renderer, doc)
        let patch = doc.selected.flatMap { renderer.livePatch($0) }
        E2E.record("smart-erase-compact-cache-bounds", first.flatMap { a in again.map { a.px == $0.px } } == true
                   && renderer.e2eCacheEntryCount == 128 && renderer.e2eCacheBytes <= 64 * 1024 * 1024
                   && renderer.e2eLiveBytes <= 16 * 1024 * 1024 && patch?.image.width == 2 && patch?.image.height == 2,
                   ["cacheBytes": renderer.e2eCacheBytes, "entries": renderer.e2eCacheEntryCount, "liveBytes": renderer.e2eLiveBytes])
        renderer.releaseTransientResources()
        E2E.record("smart-erase-resource-release", renderer.e2eCacheBytes == 0 && renderer.e2eLiveBytes == 0)
    }

    private static func nativeEditor() async {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600), rect = CGRect(x: 160, y: 200, width: 180, height: 95)
        guard let source = fixture(mark: rect, size: bounds.size), let clean = fixture(size: bounds.size) else {
            E2E.record("smart-erase-native-setup", false); return
        }
        let renderer = Renderer(frame: source, scale: 1)
        let view = EditorView(frame: bounds, renderer: renderer, mode: .rectangle, initialCrop: bounds,
                              styles: [:], showMagnifier: true, pickRects: [], finishOnPick: false)
        let window = OverlayWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFrontRegardless()
        window.makeFirstResponder(view)
        defer { view.releaseResources(); window.orderOut(nil); window.contentView = nil }
        let surface = (window: window as NSWindow, view: view)
        func key(_ code: UInt16, _ characters: String) {
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) { window.sendEvent(event) }
        }
        key(46, "m")
        E2E.mouse(.leftMouseDown, rect.origin, in: surface)
        E2E.mouse(.leftMouseDragged, CGPoint(x: rect.maxX, y: rect.maxY), in: surface)
        let live = E2E.snapshotImageLayers(view, scale: 1)
        E2E.record("smart-erase-native-drag", view.tool == .shape(.smartErase) && view.doc.annotations.count == 1
                   && live.map { difference($0, E2E.bitmap(clean), inside: Geometry.pixelRect(rect, scale: 1)) <= 1 } == true)
        E2E.mouse(.leftMouseUp, CGPoint(x: rect.maxX, y: rect.maxY), in: surface)
        let committed = E2E.snapshotImageLayers(view, scale: 1), exported = flatten(renderer, view.doc)
        E2E.record("smart-erase-native-preview-export", committed.flatMap { c in exported.map { difference(c, $0) <= 1 } } == true
                   && live.flatMap { c in exported.map { difference(c, $0) <= 1 } } == true)
        if let native = await E2E.snapshotNativeWindow(window, name: "smart-erase-native-window") {
            let inner = Geometry.pixelRect(rect.insetBy(dx: 8, dy: 8), scale: window.backingScaleFactor)
            let reference = E2E.bitmap(clean).at(Int(rect.midX), Int(rect.midY))
            E2E.record("smart-erase-native-window-pixels", native.frac(inner.cgRect) {
                abs($0.r - reference.r) <= 4.0 / 255 && abs($0.g - reference.g) <= 4.0 / 255 && abs($0.b - reference.b) <= 4.0 / 255
            } == 1)
        }
        view.undo()
        let undone = view.doc.annotations.isEmpty && flatten(renderer, view.doc)?.px == E2E.bitmap(source).px
        view.redo()
        E2E.record("smart-erase-native-undo-redo", undone && flatten(renderer, view.doc)?.px == exported?.px)
        view.setTool(.select)
        let center = CGPoint(x: rect.midX, y: rect.midY), movedCenter = CGPoint(x: rect.midX + 6, y: rect.midY + 4)
        func drag(_ start: CGPoint, _ end: CGPoint) {
            E2E.mouse(.leftMouseDown, start, in: surface)
            E2E.mouse(.leftMouseDragged, end, in: surface)
            E2E.mouse(.leftMouseUp, end, in: surface)
        }
        drag(center, movedCenter)
        let moved = E2E.snapshotImageLayers(view, scale: 1), movedExport = flatten(renderer, view.doc)
        E2E.record("smart-erase-native-move", view.doc.selected?.rect == rect.offsetBy(dx: 6, dy: 4)
                   && moved.flatMap { m in movedExport.map { difference(m, $0) <= 1 } } == true)
        view.undo()
        drag(CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.maxX + 12, y: rect.maxY + 8))
        let resized = E2E.snapshotImageLayers(view, scale: 1), resizedExport = flatten(renderer, view.doc)
        E2E.record("smart-erase-native-resize", view.doc.selected?.rect == CGRect(x: rect.minX, y: rect.minY, width: rect.width + 12, height: rect.height + 8)
                   && resized.flatMap { r in resizedExport.map { difference(r, $0) <= 1 } } == true)
        view.undo()
        renderer.e2eRejectedEffectIDs = Set(view.doc.annotations.map(\.id))
        drag(center, movedCenter)
        let failed = E2E.snapshotImageLayers(view, scale: 1)
        await E2E.wait(20)
        E2E.record("smart-erase-native-failure-status", failed.map { black($0, rect.offsetBy(dx: 6, dy: 4)) } == true
                   && view.session.status?.contains("Resize") == true)
        renderer.e2eRejectedEffectIDs = []
        view.undo()
        _ = E2E.snapshotImageLayers(view, scale: 1)
        E2E.record("smart-erase-native-recovery", renderer.smartEraseFailureRects.isEmpty && flatten(renderer, view.doc)?.px == exported?.px)
        view.setTool(.crop)
        E2E.mouse(.mouseMoved, CGPoint(x: rect.midX, y: rect.midY), in: surface)
        let concealed = !view.e2eLoupe.visible
        E2E.mouse(.mouseMoved, CGPoint(x: 600, y: 450), in: surface)
        E2E.record("smart-erase-native-loupe-protection", concealed && view.e2eLoupe.visible)

        view.setTool(.shape(.rectangle))
        view.changeStyle { $0.filled = true; $0.color = .black; $0.opacity = 1 }
        let guardArea = CGRect(x: 120, y: 180, width: 90, height: 60)
        E2E.mouse(.leftMouseDown, guardArea.origin, in: surface)
        E2E.mouse(.leftMouseDragged, CGPoint(x: guardArea.maxX, y: guardArea.maxY), in: surface)
        let guarded = E2E.snapshotImageLayers(view, scale: 1)
        E2E.record("smart-erase-native-live-protection", guarded.map { black($0, rect.union(guardArea)) } == true)
        E2E.mouse(.leftMouseUp, CGPoint(x: guardArea.maxX, y: guardArea.maxY), in: surface)
        view.undo()
        let settled = flatten(renderer, view.doc)
        var result: EditorResult?
        view.session.completion = { if case .finished(let value) = $0 { result = value } }
        key(36, "\r")
        guard let result, let encoded = Export.encode(result.image, scale: result.scale) else {
            E2E.record("smart-erase-native-delivery", false); return
        }
        let delivery = ExportDelivery(encoded: encoded, folder: E2E.out.appendingPathComponent("smart-erase-delivery").path)
        await delivery.attempt()
        let saved = delivery.savedURL.flatMap { try? Data(contentsOf: $0) }.flatMap(E2E.decode)
        let clipboard = NSPasteboard.general.data(forType: .png).flatMap(E2E.decode)
        E2E.record("smart-erase-native-delivery", delivery.complete && view.phase == .ended
                   && saved.map { E2E.bitmap($0).px == settled?.px } == true
                   && clipboard.map { E2E.bitmap($0).px == settled?.px } == true
                   && renderer.e2eCacheBytes == 0 && renderer.e2eLiveBytes == 0)
    }
}
#endif
