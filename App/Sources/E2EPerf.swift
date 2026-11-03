// Compiled only into CI test builds (SWIFT_ACTIVE_COMPILATION_CONDITIONS += SHAREX_E2E); never shipped.
#if SHAREX_E2E
import AppKit
@preconcurrency import ScreenCaptureKit
import ShareXCore

/// `--e2e <out> --perf`: timings only, written to perf.json. Retina 2x full display of a 16" M-series MacBook
/// (3456 × 2234 px, 1728 × 1117 pt) is simulated with a synthetic 2x frame; the runner's own display is 1x.
/// Frame time = main-thread work per drag event: event handling + synchronous display (CPU raster) + CATransaction flush.
/// GPU compositing in WindowServer is not included.
@MainActor
enum E2EPerf {
    static let pxW = 3456, pxH = 2234, sc: CGFloat = 2
    static var ptSize: CGSize { CGSize(width: CGFloat(pxW) / sc, height: CGFloat(pxH) / sc) }
    static var out: [String: Any] = [:]

    static func stats(_ v: [Double]) -> [String: Double] {
        let s = v.sorted(); guard !s.isEmpty else { return [:] }
        func q(_ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
        return ["n": Double(s.count), "p50": q(0.5), "p95": q(0.95), "max": s.last!, "mean": s.reduce(0, +) / Double(s.count)]
    }

    static func window(for view: EditorView) -> NSWindow {
        let w = OverlayWindow(contentRect: CGRect(origin: CGPoint(x: 0, y: 0), size: ptSize), styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.acceptsMouseMovedEvents = true
        w.contentView = view; w.orderFrontRegardless(); w.makeKey(); w.makeFirstResponder(view)
        return w
    }

    static func send(_ t: NSEvent.EventType, _ p: CGPoint, _ v: EditorView, _ w: NSWindow) {
        let wp = v.convert(p, to: nil)
        if let e = NSEvent.mouseEvent(with: t, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { w.sendEvent(e) }
    }

    /// Time one event + its frame.
    static func frame(_ t: NSEvent.EventType, _ p: CGPoint, _ v: EditorView, _ w: NSWindow) -> Double {
        let t0 = Perf.now()
        send(t, p, v, w)
        w.displayIfNeeded()
        CATransaction.flush()
        return Perf.now() - t0
    }

    static func path(_ n: Int, from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        (0..<n).map { i in let f = CGFloat(i) / CGFloat(n - 1); return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f + 30 * sin(f * 12)) }
    }

    static func run() async {
        guard let img = E2E.checker(pxW, pxH) else { return }
        out["display"] = ["px": [pxW, pxH], "scale": sc, "runnerScale": NSScreen.screens.first?.backingScaleFactor ?? 0]

        // 1. Editor construction + first frame at 2x (part of hotkey -> overlay visible).
        var builds: [Double] = []
        for _ in 0..<5 {
            let t0 = Perf.now()
            let v = EditorView(frame: CGRect(origin: .zero, size: ptSize), renderer: Renderer(frame: img, scale: sc), mode: .rectangle,
                               initialCrop: nil, styles: [:], showMagnifier: true, pickRects: [], finishOnPick: false)
            let w = window(for: v); w.displayIfNeeded(); CATransaction.flush()
            builds.append(Perf.now() - t0)
            w.orderOut(nil); w.contentView = nil
            await E2E.wait(50)
        }
        out["overlayBuildFirstFrame2x_ms"] = stats(builds)

        // 2. Region-selection drag with magnifier + crosshair.
        do {
            let v = EditorView(frame: CGRect(origin: .zero, size: ptSize), renderer: Renderer(frame: img, scale: sc), mode: .rectangle,
                               initialCrop: nil, styles: [:], showMagnifier: true, pickRects: [], finishOnPick: false)
            let w = window(for: v); w.displayIfNeeded()
            var moves: [Double] = []
            for p in path(60, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 1500, y: 900)) { moves.append(frame(.mouseMoved, p, v, w)) }
            out["hoverMove2x_ms"] = stats(moves)
            _ = frame(.leftMouseDown, CGPoint(x: 200, y: 150), v, w)
            var t: [Double] = []
            for p in path(120, from: CGPoint(x: 210, y: 160), to: CGPoint(x: 1400, y: 950)) { t.append(frame(.leftMouseDragged, p, v, w)) }
            out["regionDrag2x_ms"] = stats(t)
            _ = frame(.leftMouseUp, CGPoint(x: 1400, y: 950), v, w)
            w.orderOut(nil); w.contentView = nil
        }

        // Orientation check for the layer views, from real window pixels (ScreenCaptureKit): a uniform grey frame
        // with an editing crop in the top-left quarter must be bright top-left and dimmed bottom-right.
        do {
            let gw = 400, gh = 300
            if let g = Imaging.context(width: gw, height: gh, flipped: true) {
                g.setFillColor(CGColor(gray: 0.8, alpha: 1)); g.fill(CGRect(x: 0, y: 0, width: gw, height: gh))
                if let grey = g.makeImage() {
                    let size = CGSize(width: 200, height: 150)
                    let v = EditorView(frame: CGRect(origin: .zero, size: size), renderer: Renderer(frame: grey, scale: 2), mode: .rectangle,
                                       initialCrop: CGRect(x: 0, y: 0, width: 100, height: 75), styles: [:],
                                       showMagnifier: false, pickRects: [], finishOnPick: false)
                    let w = OverlayWindow(contentRect: CGRect(x: 100, y: 100, width: 200, height: 150), styleMask: .borderless, backing: .buffered, defer: false)
                    w.isReleasedWhenClosed = false; w.sharingType = .readOnly; w.contentView = v; w.orderFrontRegardless()
                    w.displayIfNeeded(); CATransaction.flush()
                    await E2E.wait(300)
                    var res: [String: Any] = [:]
                    do {
                        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                        if let sw = content.windows.first(where: { $0.windowID == CGWindowID(w.windowNumber) }) {
                            let cfg = SCStreamConfiguration(); cfg.width = 200; cfg.height = 150; cfg.showsCursor = false
                            let shot = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: sw), configuration: cfg)
                            if let c = CGContext(data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 800, space: Imaging.colorSpace,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                                c.draw(shot, in: CGRect(x: 0, y: 0, width: 200, height: 150))
                                let p = c.data!.assumingMemoryBound(to: UInt8.self)
                                func g(_ x: Int, _ y: Int) -> Int { Int(p[(y * 200 + x) * 4]) }   // row 0 = top
                                res = ["topLeft": g(40, 30), "bottomRight": g(160, 120), "ok": g(40, 30) > g(160, 120) + 40]
                            }
                        } else { res = ["skipped": "window not in SCShareableContent"] }
                    } catch { res = ["skipped": "\(error.localizedDescription)"] }
                    out["layerOrientation"] = res
                    w.orderOut(nil); w.contentView = nil
                }
            }
        }

        // 3. Annotation drags with 3 blur + 2 pixelate + shapes already committed.
        do {
            var styles: [ShapeKind: ShapeStyle] = [:]
            for k in ShapeKind.allCases { styles[k] = .defaults(for: k) }
            let v = EditorView(frame: CGRect(origin: .zero, size: ptSize), renderer: Renderer(frame: img, scale: sc), mode: .rectangle,
                               initialCrop: CGRect(x: 40, y: 80, width: 1640, height: 1000), styles: styles, showMagnifier: false,
                               pickRects: [], finishOnPick: false)
            let w = window(for: v); w.displayIfNeeded()
            func shape(_ k: ShapeKind, _ a: CGPoint, _ b: CGPoint) {
                v.setTool(.shape(k))
                _ = frame(.leftMouseDown, a, v, w)
                for p in path(6, from: a, to: b) { _ = frame(.leftMouseDragged, p, v, w) }
                _ = frame(.leftMouseUp, b, v, w)
            }
            shape(.blur, CGPoint(x: 100, y: 200), CGPoint(x: 500, y: 500))
            shape(.blur, CGPoint(x: 600, y: 200), CGPoint(x: 1000, y: 500))
            shape(.blur, CGPoint(x: 1100, y: 200), CGPoint(x: 1600, y: 500))
            shape(.pixelate, CGPoint(x: 100, y: 600), CGPoint(x: 500, y: 900))
            shape(.pixelate, CGPoint(x: 600, y: 600), CGPoint(x: 1000, y: 900))
            shape(.rectangle, CGPoint(x: 1100, y: 600), CGPoint(x: 1500, y: 900))
            shape(.arrow, CGPoint(x: 1200, y: 950), CGPoint(x: 1600, y: 650))
            shape(.pen, CGPoint(x: 150, y: 950), CGPoint(x: 900, y: 1000))

            func timedShape(_ k: ShapeKind, _ key: String, _ a: CGPoint, _ b: CGPoint) {
                v.setTool(.shape(k))
                _ = frame(.leftMouseDown, a, v, w)
                var t: [Double] = []
                for p in path(120, from: a, to: b) { t.append(frame(.leftMouseDragged, p, v, w)) }
                _ = frame(.leftMouseUp, b, v, w)
                out[key] = stats(t)
            }
            timedShape(.rectangle, "annotRectDrag2x_ms", CGPoint(x: 300, y: 300), CGPoint(x: 1300, y: 1000))
            timedShape(.pen, "annotPenDrag2x_ms", CGPoint(x: 300, y: 300), CGPoint(x: 1500, y: 1000))
            timedShape(.highlighter, "annotHighlighterDrag2x_ms", CGPoint(x: 200, y: 250), CGPoint(x: 1200, y: 700))
            timedShape(.blur, "annotNewBlurDrag2x_ms", CGPoint(x: 700, y: 550), CGPoint(x: 1300, y: 1000))
            // Move an existing blur (live effect recomputed as it moves).
            v.setTool(.select)
            _ = frame(.leftMouseDown, CGPoint(x: 300, y: 350), v, w)
            var mv: [Double] = []
            for p in path(120, from: CGPoint(x: 300, y: 350), to: CGPoint(x: 900, y: 700)) { mv.append(frame(.leftMouseDragged, p, v, w)) }
            _ = frame(.leftMouseUp, CGPoint(x: 900, y: 700), v, w)
            out["annotMoveBlur2x_ms"] = stats(mv)

            // 4. Commit -> clipboard ready (flatten + decorate + PNG/TIFF on the pasteboard), full 2x display crop.
            var clip: [Double] = [], save: [Double] = []
            var opts = CaptureOptions(); opts.shadow = true; opts.borderWidth = 2
            for _ in 0..<5 {
                let before = NSPasteboard.general.changeCount
                let t0 = Perf.now()
                guard let flat = Export.flatten(renderer: v.renderer, doc: v.doc, crop: CGRect(origin: .zero, size: ptSize), lasso: nil) else { break }
                let img = Export.decorate(flat, options: opts, scale: sc)
                _ = Export.copyToClipboard(img, scale: sc)
                await waitClipboard(after: before)
                clip.append(Perf.now() - t0)
                let t1 = Perf.now()
                _ = Export.savePNG(img, scale: sc, folder: NSTemporaryDirectory() + "perf")
                save.append(Perf.now() - t1)
            }
            out["commitToClipboard2x_ms"] = stats(clip)
            // What the shipped path keeps on the main thread: flatten + pasteboard write. Decorate + encode run detached.
            var mainOnly: [Double] = [], pipeline: [Double] = []
            for _ in 0..<5 {
                let t0 = Perf.now()
                guard let flat = Export.flatten(renderer: v.renderer, doc: v.doc, crop: CGRect(origin: .zero, size: ptSize), lasso: nil) else { break }
                let tFlat = Perf.now() - t0
                let box = ImageBox(image: flat), o = opts, k = sc
                let enc = await Task.detached { Export.encode(Export.decorateOffMain(box.image, options: o, scale: k), scale: k) }.value
                let t1 = Perf.now()
                if let enc { _ = Export.write(enc) }
                mainOnly.append(tFlat + Perf.now() - t1)
                pipeline.append(Perf.now() - t0)
            }
            out["commitMainThreadOnly2x_ms"] = stats(mainOnly)
            out["commitPipelineAsync2x_ms"] = stats(pipeline)
            out["savePNG2x_ms"] = stats(save)
            w.orderOut(nil); w.contentView = nil
        }

        // 5. Real path at runner resolution: capture(.region) -> overlay shown (SCK freeze if granted).
        var lat: [Double] = []
        for _ in 0..<5 {
            Perf.stamps = [:]
            let t0 = Perf.now()
            E2E.coord.capture(.region)
            let ok = await E2E.until(4000, { Perf.stamps["overlay-shown"] != nil })
            if ok, let t = Perf.stamps["overlay-shown"] { lat.append(t - t0) }
            E2E.esc(); _ = await E2E.until({ !E2E.coord.busy })
            await E2E.wait(150)
        }
        out["captureToOverlayShown_runner_ms"] = stats(lat)
        out["frameSource"] = E2E.source
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: E2E.out.appendingPathComponent("perf.json"))
            NSLog("E2E PERF %@", String(decoding: d, as: UTF8.self))
        }
    }

    static func waitClipboard(after c: Int) async {
        for _ in 0..<500 where NSPasteboard.general.changeCount == c { await Task.yield(); try? await Task.sleep(for: .milliseconds(1)) }
    }
}
#endif
