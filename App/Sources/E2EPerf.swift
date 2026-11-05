// Compiled only into CI test builds (SWIFT_ACTIVE_COMPILATION_CONDITIONS += SHAREX_E2E); never shipped.
#if SHAREX_E2E
import AppKit
@preconcurrency import ScreenCaptureKit
import ShareXCore

/// Frame time = main-thread work per drag event: event handling + synchronous display (CPU raster) + CATransaction flush.
/// GPU compositing in WindowServer is not included.
@MainActor
enum E2EPerf {
    static let pxW = 3456, pxH = 2234, sc: CGFloat = 2
    static var ptSize: CGSize { CGSize(width: CGFloat(pxW) / sc, height: CGFloat(pxH) / sc) }
    static var out: [String: Any] = [:]
    private static var errors = 0

    private static func fail(_ operation: String) {
        errors += 1
        E2E.record("perf-\(operation)", false)
    }

    static func stats(_ v: [Double]) -> [String: Double] {
        let s = v.sorted(); guard !s.isEmpty else { return [:] }
        func q(_ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
        return ["n": Double(s.count), "p50": q(0.5), "p95": q(0.95), "max": s.last!, "mean": s.reduce(0, +) / Double(s.count)]
    }

    static func window(for view: EditorView) -> NSWindow {
        let w = OverlayWindow(contentRect: CGRect(origin: CGPoint(x: 0, y: 0), size: ptSize), styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.acceptsMouseMovedEvents = true
        w.contentView = view
        w.orderFrontRegardless(); w.makeKey(); w.makeFirstResponder(view)
        return w
    }

    static func close(_ view: EditorView, _ window: NSWindow) {
        view.releaseResources()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        CATransaction.flush()
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

    static func cpuNow() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }

    /// One drag event, measured three ways:
    /// cpu = main-thread CPU time (event + any raster + layer commit), excludes time blocked waiting;
    /// wall = the same span in wall time (includes waits inside displayIfNeeded/flush);
    /// onScreen = from the event until the next display-link tick after the commit, i.e. the earliest frame it
    /// can appear in (WindowServer compositing itself is not visible to the app).
    static var samples: (cpu: [Double], wall: [Double], screen: [Double]) = ([], [], [])
    static func timed(_ t: NSEvent.EventType, _ p: CGPoint, _ v: EditorView, _ w: NSWindow, _ vs: Vsync) async {
        let t0 = Perf.now(), c0 = cpuNow()
        send(t, p, v, w)
        w.displayIfNeeded()
        CATransaction.flush()
        let c1 = cpuNow(), t1 = Perf.now()
        let tick = await vs.next()
        samples.cpu.append(c1 - c0); samples.wall.append(t1 - t0)
        if tick >= t0 { samples.screen.append(tick - t0) }
        else { fail("display-link-tick") }
    }
    static func takeSamples(_ key: String) {
        out[key] = stats(samples.cpu)
        out[key.replacingOccurrences(of: "_ms", with: "_wall_ms")] = stats(samples.wall)
        out[key.replacingOccurrences(of: "_ms", with: "_onScreen_ms")] = stats(samples.screen)
        samples = ([], [], [])
    }

    static func path(_ n: Int, from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        (0..<n).map { i in let f = CGFloat(i) / CGFloat(n - 1); return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f + 30 * sin(f * 12)) }
    }

    static func run() async {
        errors = 0
        out["schemaVersion"] = 1
        defer {
            out["errors"] = errors
            out["frameSource"] = E2E.source
            do {
                let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: E2E.out.appendingPathComponent("perf.json"), options: .atomic)
                NSLog("E2E PERF %@", String(decoding: data, as: UTF8.self))
            } catch { E2E.record("perf-write", false, ["error": error.localizedDescription]) }
        }
        guard let img = E2E.checker(pxW, pxH) else { fail("fixture"); return }
        out["display"] = ["px": [pxW, pxH], "scale": sc, "runnerScale": NSScreen.screens.first?.backingScaleFactor ?? 0]
        E2ERenderer.benchmark(image: img, scale: sc)

        // 1. Editor construction + first frame at 2x (part of hotkey -> overlay visible).
        var builds: [Double] = []
        for index in 0..<5 {
            NSLog("E2E TRACE perf editor construction %d", index)
            let elapsed = autoreleasepool {
                let t0 = Perf.now()
                let v = EditorView(frame: CGRect(origin: .zero, size: ptSize), renderer: Renderer(frame: img, scale: sc), mode: .rectangle,
                                   initialCrop: nil, styles: [:], showMagnifier: true, pickRects: [], finishOnPick: false)
                let w = window(for: v)
                defer { close(v, w) }
                w.displayIfNeeded(); CATransaction.flush()
                return Perf.now() - t0
            }
            builds.append(elapsed)
            NSLog("E2E TRACE perf editor closed %d", index)
            await E2E.wait(50)
        }
        out["overlayBuildFirstFrame2x_ms"] = stats(builds)

        // 2. Region-selection drag with magnifier + crosshair.
        do {
            NSLog("E2E TRACE perf selection begin")
            let v = EditorView(frame: CGRect(origin: .zero, size: ptSize), renderer: Renderer(frame: img, scale: sc), mode: .rectangle,
                               initialCrop: nil, styles: [:], showMagnifier: true, pickRects: [], finishOnPick: false)
            let w = window(for: v); w.displayIfNeeded()
            defer { close(v, w) }
            let vs = Vsync(w)
            NSLog("E2E TRACE perf display link ready")
            defer { vs.stop() }
            let hoverPath = path(60, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 1500, y: 900))
            for p in hoverPath { await timed(.mouseMoved, p, v, w, vs) }
            let hoverVerified = hoverPath.last.map { E2ELoupe.loupeState(v, cursor: $0, scale: sc).ok } ?? false
            out["hoverVerified"] = hoverVerified
            if !hoverVerified { fail("hover-event-delivery") }
            takeSamples("hoverMove2x_ms")
            _ = frame(.leftMouseDown, CGPoint(x: 200, y: 150), v, w)
            for p in path(120, from: CGPoint(x: 210, y: 160), to: CGPoint(x: 1400, y: 950)) { await timed(.leftMouseDragged, p, v, w, vs) }
            takeSamples("regionDrag2x_ms")
            _ = frame(.leftMouseUp, CGPoint(x: 1400, y: 950), v, w)
        }

        // On-screen orientation is checked by E2EOrientation (E2E run, fails CI).

        // 3. Annotation drags with 3 blur + 2 pixelate + shapes already committed.
        do {
            var styles: [ShapeKind: ShapeStyle] = [:]
            for k in ShapeKind.allCases { styles[k] = .defaults(for: k) }
            let v = EditorView(frame: CGRect(origin: .zero, size: ptSize), renderer: Renderer(frame: img, scale: sc), mode: .rectangle,
                               initialCrop: CGRect(x: 40, y: 80, width: 1640, height: 1000), styles: styles, showMagnifier: false,
                               pickRects: [], finishOnPick: false)
            let w = window(for: v); w.displayIfNeeded()
            defer { close(v, w) }
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
            guard v.doc.annotations.count == 8 else { fail("annotation-corpus"); return }
            let movingBlurID = v.doc.annotations.first(where: { $0.kind == .blur })?.id

            let vs = Vsync(w)
            defer { vs.stop() }
            var ups: [Double] = []
            func timedShape(_ k: ShapeKind, _ key: String, _ a: CGPoint, _ b: CGPoint) async {
                let count = v.doc.annotations.count
                v.setTool(.shape(k))
                _ = frame(.leftMouseDown, a, v, w)
                for p in path(120, from: a, to: b) { await timed(.leftMouseDragged, p, v, w, vs) }
                takeSamples(key)
                ups.append(frame(.leftMouseUp, b, v, w))   // commit into the annotation bitmap
                if v.doc.annotations.count != count + 1 || v.doc.annotations.last?.kind != k { fail("\(key)-commit") }
            }
            await timedShape(.rectangle, "annotRectDrag2x_ms", CGPoint(x: 300, y: 300), CGPoint(x: 1300, y: 1000))
            await timedShape(.pen, "annotPenDrag2x_ms", CGPoint(x: 300, y: 300), CGPoint(x: 1500, y: 1000))
            await timedShape(.highlighter, "annotHighlighterDrag2x_ms", CGPoint(x: 200, y: 250), CGPoint(x: 1200, y: 700))
            await timedShape(.blur, "annotNewBlurDrag2x_ms", CGPoint(x: 700, y: 550), CGPoint(x: 1300, y: 1000))
            // Move an existing blur (live effect recomputed as it moves).
            v.setTool(.select)
            // The newer highlighter covers x >= 200 here. Start in the uncovered first blur, not the highlighter.
            let blurStart = CGPoint(x: 150, y: 350), blurEnd = CGPoint(x: 850, y: 700)
            _ = frame(.leftMouseDown, blurStart, v, w)
            let selectedBlur = v.doc.selected?.kind == .blur && v.doc.selectedID == movingBlurID
            let blurBefore = v.doc.selected?.bounds
            E2E.record("perf-move-target-is-blur", selectedBlur,
                       ["expectedID": movingBlurID ?? -1, "selectedID": v.doc.selectedID ?? -1,
                        "selectedKind": v.doc.selected?.kind.rawValue ?? "none"])
            guard selectedBlur else {
                fail("move-blur-selection")
                _ = frame(.leftMouseUp, blurStart, v, w)
                return
            }
            for p in path(120, from: blurStart, to: blurEnd) { await timed(.leftMouseDragged, p, v, w, vs) }
            takeSamples("annotMoveBlur2x_ms")
            ups.append(frame(.leftMouseUp, blurEnd, v, w))
            if v.doc.annotations.first(where: { $0.id == movingBlurID })?.bounds == blurBefore { fail("move-blur-unchanged") }
            out["annotCommitOnMouseUp2x_wall_ms"] = stats(ups)

            // 4. Commit -> clipboard ready (flatten + decorate + PNG/TIFF on the pasteboard), full 2x display crop.
            var clip: [Double] = [], save: [Double] = []
            var opts = CaptureOptions(); opts.shadow = true; opts.borderWidth = 2
            var clipboardOK = 0, saveOK = 0, pipelineOK = 0
            for _ in 0..<5 {
                let before = NSPasteboard.general.changeCount
                let t0 = Perf.now()
                guard let flat = Export.flatten(renderer: v.renderer, doc: v.doc, crop: CGRect(origin: .zero, size: ptSize), lasso: nil),
                      let decorated = Export.decorate(flat, options: opts, scale: sc) else { fail("clipboard-flatten"); continue }
                guard Export.copyToClipboard(decorated, scale: sc), await waitClipboard(after: before) else {
                    fail("clipboard-write"); continue
                }
                let clipTime = Perf.now() - t0
                guard clipboardMatches(decorated) else { fail("clipboard-pixels"); continue }
                clip.append(clipTime); clipboardOK += 1
                let t1 = Perf.now()
                let saved = Export.savePNG(decorated, scale: sc, folder: E2E.out.appendingPathComponent("perf-saved").path)
                let saveTime = Perf.now() - t1
                guard let saved, let data = try? Data(contentsOf: saved), let savedImage = E2E.decode(data),
                      savedImage.width == decorated.width, savedImage.height == decorated.height,
                      E2E.bitmap(savedImage).px == E2E.bitmap(decorated).px else {
                    fail("save-png"); continue
                }
                save.append(saveTime); saveOK += 1
            }
            out["commitToClipboard2x_ms"] = stats(clip)
            // What the shipped path keeps on the main thread: flatten + pasteboard write. Decorate + encode run detached.
            var mainOnly: [Double] = [], pipeline: [Double] = []
            for _ in 0..<5 {
                let t0 = Perf.now()
                guard let flat = Export.flatten(renderer: v.renderer, doc: v.doc, crop: CGRect(origin: .zero, size: ptSize), lasso: nil) else {
                    fail("pipeline-flatten"); continue
                }
                let tFlat = Perf.now() - t0
                let box = ImageBox(image: flat), o = opts, k = sc
                let enc = await Task.detached { Export.encode(Export.decorateOffMain(box.image, options: o, scale: k), scale: k) }.value
                let t1 = Perf.now()
                guard let enc, Export.write(enc) else { fail("pipeline-write"); continue }
                let mainTime = tFlat + Perf.now() - t1, pipelineTime = Perf.now() - t0
                guard let expected = Export.decorate(flat, options: o, scale: k), clipboardMatches(expected),
                      NSPasteboard.general.data(forType: .png) == enc.png,
                      NSPasteboard.general.data(forType: .tiff) == enc.tiff else { fail("pipeline-output"); continue }
                mainOnly.append(mainTime); pipeline.append(pipelineTime); pipelineOK += 1
            }
            out["commitMainThreadOnly2x_ms"] = stats(mainOnly)
            out["commitPipelineAsync2x_ms"] = stats(pipeline)
            out["savePNG2x_ms"] = stats(save)
            out["outputCorrectness"] = ["clipboard": clipboardOK, "savePNG": saveOK, "asyncPipeline": pipelineOK, "attemptsPerOperation": 5]
        }

        // 5. Real path at runner resolution: capture(.region) -> overlay shown (SCK freeze if granted).
        var lat: [Double] = []
        for _ in 0..<5 {
            Perf.stamps = [:]
            let t0 = Perf.now()
            E2E.coord.capture(.region)
            let ok = await E2E.until(4000, { Perf.stamps["overlay-shown"] != nil })
            if ok, let t = Perf.stamps["overlay-shown"], E2E.surface() != nil { lat.append(t - t0) }
            else { fail("capture-overlay") }
            E2E.esc()
            if !(await E2E.until({ !E2E.coord.busy && E2E.coord.overlay == nil })) { fail("capture-cleanup") }
            await E2E.wait(150)
        }
        out["captureToOverlayShown_runner_ms"] = stats(lat)
    }

    /// Resolves at the window's next display-link tick (or -1 after 100 ms when the runner never ticks).
    @MainActor final class Vsync: NSObject {
        private var token = 0
        private var link: CADisplayLink?
        private var cont: CheckedContinuation<Double, Never>?
        init(_ w: NSWindow) {
            super.init()
            link = w.displayLink(target: self, selector: #selector(tick(_:)))
            link?.isPaused = true
            link?.add(to: .main, forMode: .common)
        }
        func stop() { link?.invalidate(); resume(-1) }
        @objc func tick(_ l: CADisplayLink) { resume(Perf.now()) }
        private func resume(_ v: Double) { link?.isPaused = true; let c = cont; cont = nil; c?.resume(returning: v) }
        func next() async -> Double {
            await withCheckedContinuation { c in
                token += 1; let t = token
                cont = c; link?.isPaused = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { if self.token == t { self.resume(-1) } } }
            }
        }
    }

    static func waitClipboard(after c: Int) async -> Bool {
        for _ in 0..<500 where NSPasteboard.general.changeCount == c { await Task.yield(); try? await Task.sleep(for: .milliseconds(1)) }
        return NSPasteboard.general.changeCount != c
    }

    private static func clipboardMatches(_ image: CGImage) -> Bool {
        let pasteboard = NSPasteboard.general
        guard pasteboard.pasteboardItems?.count == 1,
              let pngData = pasteboard.data(forType: .png), let tiffData = pasteboard.data(forType: .tiff),
              let png = E2E.decode(pngData), let tiff = E2E.decode(tiffData),
              png.width == image.width, png.height == image.height, tiff.width == image.width, tiff.height == image.height else { return false }
        let expected = E2E.bitmap(image).px
        return E2E.bitmap(png).px == expected && E2E.bitmap(tiff).px == expected
    }
}
#endif

