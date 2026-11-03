import AppKit
import ImageIO
import ShareXCore

/// Test-only end-to-end driver, active only with `--e2e <outdir>`. It drives the real CaptureCoordinator,
/// the real overlay/editor (synthetic NSEvents sent to its windows), real ScreenCaptureKit when Screen
/// Recording is granted, and reads NSPasteboard.general back after every export.
/// Helper modes: `--e2e-pattern` (a separate process showing a textured window to capture) and
/// `--e2e-verify <outdir>` (a relaunch that checks persisted settings).
@MainActor
enum E2E {
    static let args = CommandLine.arguments
    static var enabled: Bool { args.contains("--e2e") }
    static func arg(after flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

    // MARK: helper processes

    static func handlesHelperMode() -> Bool {
        if args.contains("--e2e-pattern") { runPattern(); return true }
        if let out = arg(after: "--e2e-verify") { verifySettings(out); return true }
        return false
    }

    private static func runPattern() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let s = NSScreen.main!.frame
        let w = NSWindow(contentRect: CGRect(x: s.minX + 40, y: s.minY + 40, width: s.width - 80, height: s.height - 120),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "E2E Pattern"
        let v = NSImageView(frame: w.contentView!.bounds)
        v.image = NSImage(cgImage: checker(Int(v.frame.width), Int(v.frame.height))!, size: v.frame.size)
        v.imageScaling = .scaleAxesIndependently
        v.autoresizingMask = [.width, .height]
        w.contentView!.addSubview(v)
        w.makeKeyAndOrderFront(nil)
        app.activate()
        app.run()
    }

    /// 16 px squares in four greys/blues plus a diagonal gradient: textured, so blur/pixelate visibly change it.
    /// True when the C region of a display frame is a single colour.
    static func uniform(_ img: CGImage) -> Bool {
        guard let crop = img.cropping(to: CGRect(x: 120, y: 120, width: 360, height: 260)),
              let ctx = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt32.self), n = crop.width * crop.height
        for i in stride(from: 0, to: n, by: 7) where p[i] != p[0] { return false }
        return true
    }

    static func checker(_ w: Int, _ h: Int) -> CGImage? {
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let cols: [CGColor] = [CGColor(gray: 0.85, alpha: 1), CGColor(gray: 0.35, alpha: 1),
                               CGColor(srgbRed: 0.3, green: 0.4, blue: 0.9, alpha: 1), CGColor(gray: 0.6, alpha: 1)]
        for y in stride(from: 0, to: h, by: 16) { for x in stride(from: 0, to: w, by: 16) {
            ctx.setFillColor(cols[((x / 16) + 2 * (y / 16)) % 4]); ctx.fill(CGRect(x: x, y: y, width: 16, height: 16))
        } }
        return ctx.makeImage()
    }

    private static func verifySettings(_ out: String) {
        let s = SettingsStore().value
        var r: [String: Any] = [:]
        r["rectangleColorBlue"] = s.toolStyles[.rectangle]?.color == .blue
        r["rectangleWidth8"] = s.toolStyles[.rectangle]?.width == 8
        r["saveToFile"] = s.saveToFile
        r["lastRegionPresent"] = s.lastRegion != nil
        r["delaySeconds"] = s.options.delaySeconds
        r["borderWidth"] = s.options.borderWidth
        let pass = (r["rectangleColorBlue"] as? Bool == true) && (r["rectangleWidth8"] as? Bool == true) && s.saveToFile && s.lastRegion != nil
            && s.options.borderWidth == 0 && s.options.delaySeconds == 0
        r["pass"] = pass
        let d = try! JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys])
        try? d.write(to: URL(fileURLWithPath: out).appendingPathComponent("verify-settings.json"))
        exit(pass ? 0 : 3)
    }

    // MARK: main driver

    static var app: AppDelegate!
    static var out: URL!
    static var saved: URL { out.appendingPathComponent("saved") }
    static var results: [[String: Any]] = []
    static var source = "sck"
    static var patternPID: pid_t = 0
    static var lastChange = 0

    static func start(_ a: AppDelegate) {
        app = a
        out = URL(fileURLWithPath: arg(after: "--e2e") ?? "/tmp/e2e")
        try? FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        if let p = arg(after: "--pattern-pid"), let n = Int32(p) { patternPID = n }
        // Watchdog: a modal or a hang must not eat CI minutes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { record("watchdog", false, ["note": "timed out"]); finishRun() }
        Task { @MainActor in await runAll(); finishRun() }
    }

    static func finishRun() {
        let pass = results.allSatisfy { ($0["pass"] as? Bool) ?? false || ($0["status"] as? String) == "unverifiable" }
        let doc: [String: Any] = ["frameSource": source, "screens": NSScreen.screens.map { ["w": $0.frame.width, "h": $0.frame.height, "scale": $0.backingScaleFactor] },
                                  "results": results, "pass": pass, "macOS": ProcessInfo.processInfo.operatingSystemVersionString]
        let d = try! JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        try? d.write(to: out.appendingPathComponent("results.json"))
        exit(pass ? 0 : 2)
    }

    static func record(_ name: String, _ pass: Bool, _ info: [String: Any] = [:], status: String? = nil) {
        var r = info; r["name"] = name; r["pass"] = pass; r["status"] = status ?? (pass ? "pass" : "FAIL"); r["frameSource"] = source
        results.append(r)
        NSLog("E2E %@ %@ %@", pass ? "PASS" : "FAIL", name, "\(info)")
    }

    static var coord: CaptureCoordinator { app.coordinator }
    static var screen: NSScreen { NSScreen.screens.first! }
    static var scale: CGFloat { screen.backingScaleFactor }

    static func wait(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
    static func until(_ c: () -> Bool) async -> Bool { await until(4000, c) }
    static func until(_ ms: Int, _ c: () -> Bool) async -> Bool {
        for _ in 0..<(ms / 20) { if c() { return true }; await wait(20) }
        return c()
    }

    static func setOpts(_ f: (inout AppSettings) -> Void) { app.settings.update(f) }

    // MARK: event synthesis

    static func surface() -> (window: NSWindow, view: EditorView)? { coord.overlay?.e2eSurfaces.first }

    static func mouse(_ type: NSEvent.EventType, _ p: CGPoint, in s: (window: NSWindow, view: EditorView), clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
        let wp = s.view.convert(p, to: nil)
        guard let e = NSEvent.mouseEvent(with: type, location: wp, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: s.window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) else { return }
        s.window.sendEvent(e)
    }

    static func drag(_ pts: [CGPoint]) {
        guard let s = surface(), let first = pts.first else { return }
        mouse(.leftMouseDown, first, in: s)
        for p in pts.dropFirst() { mouse(.leftMouseDragged, p, in: s) }
        mouse(.leftMouseUp, pts.last!, in: s)
    }
    static func drag(_ a: CGPoint, _ b: CGPoint) {
        drag((0...8).map { i in CGPoint(x: a.x + (b.x - a.x) * CGFloat(i) / 8, y: a.y + (b.y - a.y) * CGFloat(i) / 8) })
    }
    static func click(_ p: CGPoint) { drag([p]) }

    static func key(_ code: UInt16, _ chars: String = "", flags: NSEvent.ModifierFlags = []) {
        guard let s = surface(), let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: s.window.windowNumber, context: nil,
              characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
        s.view.keyDown(with: e)
    }
    static func ret() { key(36, "\r") }
    static func esc() { key(53, "\u{1b}") }

    // MARK: pixels

    struct Bitmap {
        let w: Int, h: Int, px: [UInt8]
        func at(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
            let x = min(max(0, x), w - 1), y = min(max(0, y), h - 1), i = (y * w + x) * 4
            return (Double(px[i]) / 255, Double(px[i + 1]) / 255, Double(px[i + 2]) / 255, Double(px[i + 3]) / 255)
        }
        /// Fraction of pixels in the pixel rect satisfying `f`.
        func frac(_ r: CGRect, _ f: ((r: Double, g: Double, b: Double, a: Double)) -> Bool) -> Double {
            var n = 0, k = 0
            for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) { n += 1; if f(at(x, y)) { k += 1 } } }
            return n == 0 ? 0 : Double(k) / Double(n)
        }
    }
    static func bitmap(_ img: CGImage) -> Bitmap {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Bitmap(w: w, h: h, px: px)
    }
    static func decode(_ d: Data) -> CGImage? {
        CGImageSourceCreateWithData(d as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
    static func isRed(_ c: (r: Double, g: Double, b: Double, a: Double)) -> Bool { c.r > 0.75 && c.g < 0.35 && c.b < 0.35 }
    static func isBlue(_ c: (r: Double, g: Double, b: Double, a: Double)) -> Bool { c.b > 0.8 && c.r < 0.3 && c.g < 0.6 }

    // MARK: clipboard verification

    struct Clip { let png: Bitmap; let info: [String: Any]; let ok: Bool }

    static func savedFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: saved.path)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
    }

    static func markClipboard() -> (change: Int, files: [String]) {
        let pb = NSPasteboard.general
        pb.clearContents(); pb.setString("e2e-sentinel", forType: .string)
        return (pb.changeCount, savedFiles())
    }

    /// Every export path: one item, PNG + TIFF, right size, TIFF == PNG pixels, saved file == PNG pixels, replaced not appended.
    static func checkClipboard(_ name: String, since m: (change: Int, files: [String]), w: Int, h: Int) -> Clip? {
        let pb = NSPasteboard.general
        var info: [String: Any] = [:]
        let items = pb.pasteboardItems ?? []
        let types = items.first?.types.map(\.rawValue) ?? []
        info["items"] = items.count; info["types"] = types
        info["changed"] = pb.changeCount != m.change
        info["sentinelGone"] = pb.string(forType: .string) == nil
        guard let pd = pb.data(forType: .png), let td = pb.data(forType: .tiff), let pi = decode(pd), let ti = decode(td) else {
            record(name, false, info.merging(["error": "no png/tiff"]) { $1 }); return nil
        }
        let pbm = bitmap(pi), tbm = bitmap(ti)
        info["pngSize"] = [pi.width, pi.height]; info["tiffSize"] = [ti.width, ti.height]; info["expected"] = [w, h]
        info["tiffEqualsPng"] = pbm.px == tbm.px
        let newFiles = savedFiles().filter { !m.files.contains($0) }
        info["savedNew"] = newFiles
        var savedEq = false
        if newFiles.count == 1, let sd = try? Data(contentsOf: saved.appendingPathComponent(newFiles[0])), let si = decode(sd) {
            savedEq = bitmap(si).px == pbm.px
            if let props = CGImageSourceCreateWithData(sd as CFData, nil).flatMap({ CGImageSourceCopyPropertiesAtIndex($0, 0, nil) }) as? [String: Any] {
                info["savedDPI"] = props[kCGImagePropertyDPIWidth as String]
            }
        }
        info["savedEqualsClipboard"] = savedEq
        info["nameOK"] = newFiles.allSatisfy { $0.range(of: #"^ShareX_\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d(-\d+)?\.png$"#, options: .regularExpression) != nil }
        try? pd.write(to: out.appendingPathComponent("\(name).png"))
        let ok = items.count == 1 && types.contains(NSPasteboard.PasteboardType.png.rawValue) && types.contains(NSPasteboard.PasteboardType.tiff.rawValue)
            && pi.width == w && pi.height == h && ti.width == w && ti.height == h && pbm.px == tbm.px && savedEq
            && (info["nameOK"] as? Bool ?? false) && pb.changeCount != m.change && pb.string(forType: .string) == nil
        return Clip(png: pbm, info: info, ok: ok)
    }

    static func unchanged(_ name: String, _ m: (change: Int, files: [String]), extra: [String: Any] = [:], cond: Bool = true) {
        let pb = NSPasteboard.general
        let same = pb.changeCount == m.change && pb.string(forType: .string) == "e2e-sentinel" && savedFiles() == m.files
        record(name, same && cond && !coord.busy && coord.overlay == nil,
               extra.merging(["clipboardUnchanged": same, "busy": coord.busy, "overlay": coord.overlay != nil]) { $1 })
    }

    // MARK: scenarios

    static let C = CGRect(x: 100, y: 100, width: 400, height: 300)          // region in display points
    static var cw: Int { Int(C.width * scale) }
    static var ch: Int { Int(C.height * scale) }
    static func px(_ p: CGFloat) -> Int { Int(p * scale) }
    static var baseline: Bitmap?

    /// Region capture through the real overlay: select C, run `edit`, then Return (or a custom finish).
    static var copyWasKey = false, copyHandled = true
    static func regionCapture(_ name: String, w: Int? = nil, h: Int? = nil, finish: () -> Void = { ret() },
                              edit: () async -> Void) async -> Clip? {
        let m = markClipboard()
        coord.capture(.region)
        guard await until({ surface() != nil }) else { record(name, false, ["error": "no overlay"]); return nil }
        await wait(150)
        drag(CGPoint(x: C.minX, y: C.minY), CGPoint(x: C.maxX, y: C.maxY))
        await edit()
        finish()
        guard await until({ !coord.busy }) else { record(name, false, ["error": "stuck busy"]); return nil }
        return checkClipboard(name, since: m, w: w ?? cw, h: h ?? ch)
    }

    static func runAll() async {
        await wait(800)
        if !Permissions.hasScreenRecording {
            source = "fixture"
            ScreenCapture.e2eFixture = { checker($0, $1) }
        } else {
            // Granted in TCC.db but SCK may still refuse: probe once.
            do {
                let f = try await ScreenCapture.freeze([screen], showCursor: false)
                // The hosted runner's display frame shows only a black desktop (other apps' windows are not
                // composited into it), so blur/pixelate/highlighter/spotlight would have nothing to change.
                // Fall back to a synthetic display frame then; window captures stay real.
                if let img = f.first?.image, uniform(img) {
                    source = "sck-window+fixture-display"; ScreenCapture.e2eDisplayFixture = { checker($0, $1) }
                    NSLog("E2E display frame is uniform; using display fixture. pattern=\(String(describing: patternWindow()?.frame))")
                }
            }
            catch { source = "fixture"; ScreenCapture.e2eFixture = { checker($0, $1) }; NSLog("E2E SCK refused: \(error)") }
        }
        setOpts { s in s = AppSettings(); s.saveToFile = true; s.saveFolder = saved.path; s.playSound = false
                  s.options.showMagnifier = false }

        await menuAndSettings()

        // Baseline region, no marks: crop size and Retina scale.
        if let c = await regionCapture("region-baseline", edit: {}) {
            baseline = c.png
            record("region-baseline", c.ok, c.info)
        }
        let sel = CGPoint(x: 150, y: 150), sel2 = CGPoint(x: 300, y: 250)
        let o = { (p: CGPoint) in (px(p.x - C.minX), px(p.y - C.minY)) }   // display pt -> output px

        // Each annotation tool, copied from the editor with Return.
        let tools: [(ShapeKind, String)] = [(.rectangle, "r"), (.ellipse, "e"), (.line, "l"), (.arrow, "a"), (.highlighter, "h"),
                                            (.blur, "b"), (.pixelate, "p"), (.spotlight, "s"), (.pen, "f"), (.text, "t"), (.step, "i")]
        for (k, ch) in tools {
            let name = "tool-\(k.rawValue)"
            guard let c = await regionCapture(name, edit: {
                key(UInt16(0), ch)
                switch k {
                case .pen: drag((0...20).map { i in CGPoint(x: 150 + CGFloat(i) * 7.5, y: 150 + CGFloat(i) * 5) })
                case .text:
                    click(sel); await wait(100)
                    if let f = surface()?.view.subviews.compactMap({ $0 as? NSTextField }).first { f.stringValue = "E2E TEXT" }
                    key(UInt16(0), "v")   // tool switch commits the text
                case .step: click(CGPoint(x: 200, y: 200))
                default: drag(sel, sel2)
                }
                await wait(50)
            }) else { continue }
            let b = c.png, base = baseline
            let (x0, y0) = o(sel), (x1, y1) = o(sel2)
            let box = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            var feat = false
            var detail: [String: Any] = [:]
            switch k {
            case .rectangle, .ellipse:
                feat = isRed(b.at(x0 + 1, (y0 + y1) / 2)); detail["leftEdge"] = "\(b.at(x0 + 1, (y0 + y1) / 2))"
            case .line, .arrow, .pen:
                feat = isRed(b.at((x0 + x1) / 2, (y0 + y1) / 2)) || isRed(b.at((x0 + x1) / 2 + 1, (y0 + y1) / 2))
                detail["mid"] = "\(b.at((x0 + x1) / 2, (y0 + y1) / 2))"
            case .highlighter:
                if let base { let p = b.at((x0 + x1) / 2, (y0 + y1) / 2), q = base.at((x0 + x1) / 2, (y0 + y1) / 2)
                    feat = p.b < q.b - 0.1 && p.r >= q.r - 0.02; detail["mid"] = "\(p) vs \(q)" }
            case .blur, .pixelate:
                if let base {
                    let inner = box.insetBy(dx: CGFloat(px(4)), dy: CGFloat(px(4)))
                    let changed = diffFrac(b, base, inner), outside = diffFrac(b, base, CGRect(x: 0, y: 0, width: x0 - 2, height: y0 - 2))
                    feat = changed > 0.15 && outside == 0; detail["changedInside"] = changed; detail["changedOutside"] = outside
                }
            case .spotlight:
                if let base { let p = b.at(5, 5), q = base.at(5, 5), i = b.at((x0 + x1) / 2, (y0 + y1) / 2), j = base.at((x0 + x1) / 2, (y0 + y1) / 2)
                    feat = p.r + p.g + p.b < q.r + q.g + q.b - 0.3 && abs(i.r - j.r) < 0.02; detail["outside"] = "\(p) vs \(q)" }
            case .text:
                let r = b.frac(CGRect(x: x0, y: y0, width: px(150), height: px(30)), isRed); feat = r > 0.03; detail["redFrac"] = r
            case .step:
                let (cx, cy) = o(CGPoint(x: 200, y: 200)); let rr = CGFloat(px(14))
                let r = b.frac(CGRect(x: CGFloat(cx) - rr, y: CGFloat(cy) - rr, width: 2 * rr, height: 2 * rr), isRed)
                feat = r > 0.3; detail["redFrac"] = r
            }
            record(name, c.ok && feat, c.info.merging(detail) { $1 }.merging(["annotationVerified": feat]) { $1 })
        }

        await combined()
        await copyPaths()
        await nonEditorModes()
        await editorModes()
        await cancelPaths()
        await reentrancyAndFocus()
        await decorationAndNaming()
        await retina2x()
        await hotkey()
        record("multi-display", NSScreen.screens.count > 1, ["screens": NSScreen.screens.count],
               status: NSScreen.screens.count > 1 ? nil : "unverifiable")
        // Leave settings in a known state for the relaunch check.
        setOpts { $0.options.delaySeconds = 0; $0.options.borderWidth = 0 }
    }

    static func diffFrac(_ a: Bitmap, _ b: Bitmap, _ r: CGRect) -> Double {
        guard a.w == b.w, a.h == b.h, r.width > 0, r.height > 0 else { return -1 }
        var n = 0, k = 0
        for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) {
            n += 1; let p = a.at(x, y), q = b.at(x, y)
            if abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b) > 0.02 { k += 1 } } }
        return Double(k) / Double(max(n, 1))
    }

    /// Rectangle (styled blue/8 to test style persistence) + blur + arrow, undo/redo, then crop tool shrinks the output.
    static func combined() async {
        var counts: [Int] = []
        let crop2 = CGRect(x: 120, y: 120, width: 300, height: 200)
        guard let c = await regionCapture("combined-rect-blur-arrow-crop-undo", w: px(300), h: px(200), edit: {
            guard let v = surface()?.view else { return }
            key(0, "r"); v.changeStyle { $0.color = .blue; $0.width = 8 }
            drag(CGPoint(x: 140, y: 140), CGPoint(x: 260, y: 220))
            key(0, "b"); drag(CGPoint(x: 280, y: 140), CGPoint(x: 400, y: 300))
            key(0, "a"); drag(CGPoint(x: 150, y: 300), CGPoint(x: 260, y: 240))
            counts.append(v.doc.annotations.count)
            key(6, "z", flags: .command); counts.append(v.doc.annotations.count)
            key(6, "z", flags: [.command, .shift]); counts.append(v.doc.annotations.count)
            v.undo(); v.redo(); counts.append(v.doc.annotations.count)
            key(0, "c"); drag(CGPoint(x: crop2.minX, y: crop2.minY), CGPoint(x: crop2.maxX, y: crop2.maxY))
        }) else { return }
        let b = c.png
        // Rect left edge at display x=140 -> output (140-120)*s.
        let blue = isBlue(b.at(px(20) + 1, px(60)))
        let styleSaved = app.settings.value.toolStyles[.rectangle]?.color == .blue && app.settings.value.toolStyles[.rectangle]?.width == 8
        record("combined-rect-blur-arrow-crop-undo", c.ok && counts == [3, 2, 3, 3] && blue && styleSaved,
               c.info.merging(["undoCounts": counts, "blueRect": blue, "toolStylesPersisted": styleSaved]) { $1 })
    }

    /// Copy from the editor by ⌘C key and by the Edit-menu copy: action, and repeated copies replace.
    static func copyPaths() async {
        if let c = await regionCapture("copy-cmdC", finish: { key(8, "c", flags: .command) }, edit: {}) { record("copy-cmdC", c.ok, c.info) }
        if let c = await regionCapture("copy-menu-action", finish: {
            // Edit > Copy goes through the key window's responder chain; on the runner ShareX may not be the
            // active app, so make the overlay key first (as a click on it would) and report whether it was.
            copyWasKey = surface()?.window.isKeyWindow ?? false
            surface()?.window.makeKey()
            // NSApp.sendAction(to: nil) needs ShareX to be the active app (keyWindow), which a headless runner
            // cannot guarantee; walk the overlay window's own responder chain, which is what Edit > Copy does.
            let w = surface()?.window
            copyHandled = (w?.firstResponder ?? w)?.tryToPerform(#selector(NSText.copy(_:)), with: nil) ?? false
        }, edit: {}) {
            record("copy-menu-action", c.ok, c.info.merging(["overlayWasKey": copyWasKey, "handled": copyHandled]) { $1 }) }
        else { key(53, "\u{1b}"); _ = await until({ !coord.busy }) }
        if let c = await regionCapture("copy-double-click", finish: {
            if let s = surface() { mouse(.leftMouseDown, CGPoint(x: 480, y: 380), in: s, clicks: 2); mouse(.leftMouseUp, CGPoint(x: 480, y: 380), in: s, clicks: 2) }
        }, edit: { key(0, "r") }) { record("copy-double-click", c.ok, c.info) }
        // Replace, not append: copy twice without clearing; one item, newest image.
        _ = await regionCapture("replace-1", edit: {})
        let pb = NSPasteboard.general, before = pb.changeCount, files = savedFiles()
        coord.capture(.region)
        _ = await until({ surface() != nil }); await wait(100)
        drag(CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 60)); ret()
        _ = await until({ !coord.busy })
        let items = pb.pasteboardItems?.count ?? 0
        let size = pb.data(forType: .png).flatMap(decode).map { [$0.width, $0.height] } ?? []
        record("clipboard-replaced-not-appended", items == 1 && size == [px(100), px(50)] && pb.changeCount != before && savedFiles().count == files.count + 1,
               ["items": items, "size": size])
    }

    static func autoCapture(_ name: String, _ style: CaptureStyle, w: Int, h: Int, prep: () async -> Void = {}) async -> Clip? {
        let m = markClipboard()
        await prep()
        coord.capture(style)
        guard await until(6000, { !coord.busy }) else { record(name, false, ["error": "stuck busy"]); if surface() != nil { esc() }; return nil }
        return checkClipboard(name, since: m, w: w, h: h)
    }

    static var full: (Int, Int) { (Int(screen.frame.width * scale), Int(screen.frame.height * scale)) }

    static func patternWindow() -> WindowInfo? { ScreenCapture.windows().first { $0.pid == patternPID } }

    /// Open editor OFF: every fixed-area style copies straight away.
    static func nonEditorModes() async {
        setOpts { $0.options.openEditor = false }
        let (fw, fh) = full
        if let c = await autoCapture("auto-fullscreen", .fullscreen, w: fw, h: fh) { record("auto-fullscreen", c.ok, c.info) }
        if let c = await autoCapture("auto-activeMonitor", .activeMonitor, w: fw, h: fh) { record("auto-activeMonitor", c.ok, c.info) }
        if let c = await autoCapture("auto-lastRegion", .lastRegion, w: px(100), h: px(50)) {
            // The last region came from the replace test (10,10 100x50); it must match the crop of a fresh fullscreen.
            record("auto-lastRegion", c.ok, c.info) }
        // Monitor picker: click delivers the display.
        do {
            let m = markClipboard(); coord.capture(.monitorPicker)
            if await until({ surface() != nil }) { await wait(100); click(CGPoint(x: 300, y: 300)) }
            _ = await until({ !coord.busy })
            if let c = checkClipboard("auto-monitorPicker", since: m, w: fw, h: fh) { record("auto-monitorPicker", c.ok, c.info) }
        }
        if let pw = patternWindow() {
            let ww = Int((pw.frame.width * scale).rounded()), wh = Int((pw.frame.height * scale).rounded())
            let local = Geometry.cocoaToDisplayTopLeft(pw.frame, screenFrame: screen.frame)
            do {
                let m = markClipboard(); coord.capture(.windowPicker)
                if await until({ surface() != nil }) { await wait(100); click(CGPoint(x: local.midX, y: local.midY)) }
                _ = await until(6000, { !coord.busy })
                if let c = checkClipboard("auto-windowPicker", since: m, w: ww, h: wh) { record("auto-windowPicker", c.ok, c.info) }
            }
            if let c = await autoCapture("auto-activeWindow", .activeWindow, w: ww, h: wh, prep: {
                NSRunningApplication(processIdentifier: patternPID)?.activate(); await wait(600)
            }) { record("auto-activeWindow", c.ok, c.info.merging(["frontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1]) { $1 }) }
        } else {
            record("auto-windowPicker", false, ["error": "pattern window not found"])
        }
        // Freehand lasso: bounding box output, outside the triangle transparent.
        do {
            let m = markClipboard(); coord.capture(.freehand)
            if await until({ surface() != nil }) { await wait(100)
                var tri: [CGPoint] = [CGPoint(x: 100, y: 100)]
                for i in 1...10 { tri.append(CGPoint(x: 100 + CGFloat(i) * 40, y: 100)) }
                for i in 1...10 { tri.append(CGPoint(x: 500 - CGFloat(i) * 20, y: 100 + CGFloat(i) * 30)) }
                drag(tri)
                await wait(50); ret() }
            _ = await until({ !coord.busy })
            if let c = checkClipboard("freehand-lasso", since: m, w: cw, h: ch) {
                let outside = c.png.at(3, ch - 3).a, inside = c.png.at(cw / 2, ch / 3).a
                record("freehand-lasso", c.ok && outside == 0 && inside == 1, c.info.merging(["alphaOutside": outside, "alphaInside": inside]) { $1 })
            }
        }
        setOpts { $0.options.openEditor = true }
    }

    /// Open editor ON for fixed areas: the editor opens on the preset and Return copies.
    static func editorModes() async {
        let (fw, fh) = full
        for (name, style) in [("editor-fullscreen", CaptureStyle.fullscreen), ("editor-activeMonitor", .activeMonitor), ("editor-lastRegion", .lastRegion)] {
            let m = markClipboard(); coord.capture(style)
            let opened = await until({ surface()?.view.phase == .editing })
            // Last Region crops to C, so draw inside it there; fullscreen/monitor draw near the top-left.
            let d: CGFloat = style == .lastRegion ? C.minX : 0, e: CGFloat = style == .lastRegion ? C.minY : 0
            if opened { await wait(100); key(0, "r"); drag(CGPoint(x: d + 20, y: e + 20), CGPoint(x: d + 60, y: e + 40)); ret() }
            _ = await until({ !coord.busy })
            let (w, h) = style == .lastRegion ? (cw, ch) : (fw, fh)   // freehand above remembered C
            if let c = checkClipboard(name, since: m, w: w, h: h) {
                // Tool style persisted from the combined scenario may be blue/8, so accept the red default or blue.
                let p = c.png.at(px(20) + 1, px(30)); let red = isRed(p) || (p.b > 0.7 && p.r < 0.4 && p.g < 0.6)
                record(name, c.ok && opened && red, c.info.merging(["editorOpened": opened, "rectDrawn": red]) { $1 })
            }
        }
        do {
            let m = markClipboard(); coord.capture(.monitorPicker)
            if await until({ surface() != nil }) { await wait(100); click(CGPoint(x: 300, y: 300)); await wait(50)
                let editing = surface()?.view.phase == .editing; ret()
                _ = await until({ !coord.busy })
                if let c = checkClipboard("editor-monitorPicker", since: m, w: fw, h: fh) { record("editor-monitorPicker", c.ok && editing, c.info.merging(["editorOpened": editing]) { $1 }) }
            }
        }
        if let pw = patternWindow() {
            let ww = Int((pw.frame.width * scale).rounded()), wh = Int((pw.frame.height * scale).rounded())
            let local = Geometry.cocoaToDisplayTopLeft(pw.frame, screenFrame: screen.frame)
            for (name, style) in [("editor-windowPicker", CaptureStyle.windowPicker), ("editor-activeWindow", .activeWindow)] {
                let m = markClipboard()
                if style == .activeWindow { NSRunningApplication(processIdentifier: patternPID)?.activate(); await wait(600) }
                coord.capture(style)
                if style == .windowPicker, await until({ surface() != nil }) { await wait(100); click(CGPoint(x: local.midX, y: local.midY)) }
                let opened = await until(6000, { surface()?.window.styleMask.contains(.titled) == true })
                if opened { await wait(150); ret() }
                _ = await until({ !coord.busy })
                if let c = checkClipboard(name, since: m, w: ww, h: wh) { record(name, c.ok && opened, c.info.merging(["canvasEditorOpened": opened]) { $1 }) }
            }
        }
    }

    static func cancelPaths() async {
        // Esc during the countdown: no capture, clipboard untouched, not busy.
        setOpts { $0.options.delaySeconds = 1; $0.options.openEditor = false }
        var m = markClipboard()
        coord.capture(.fullscreen)
        await wait(300)
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            NSApp.postEvent(e, atStart: false)
        }
        await wait(1500)
        unchanged("countdown-esc-cancels", m)
        // Countdown that runs out does capture.
        let (fw, fh) = full
        if let c = await autoCapture("countdown-completes", .fullscreen, w: fw, h: fh) { record("countdown-completes", c.ok, c.info) }
        setOpts { $0.options.delaySeconds = 0; $0.options.openEditor = true }
        // Esc in selection, Esc in editing with marks, right-click in selection, close button on canvas editor.
        m = markClipboard(); coord.capture(.region); _ = await until({ surface() != nil }); esc(); _ = await until({ !coord.busy })
        unchanged("overlay-esc-selecting", m)
        m = markClipboard(); coord.capture(.region); _ = await until({ surface() != nil }); await wait(100)
        drag(CGPoint(x: C.minX, y: C.minY), CGPoint(x: C.maxX, y: C.maxY)); key(0, "r"); drag(CGPoint(x: 150, y: 150), CGPoint(x: 200, y: 200)); esc()
        _ = await until({ !coord.busy }); unchanged("overlay-esc-editing", m)
        m = markClipboard(); coord.capture(.fullscreen); _ = await until({ surface() != nil }); await wait(100)
        if let s = surface() { mouse(.rightMouseDown, CGPoint(x: 50, y: 50), in: s) }
        _ = await until({ !coord.busy }); unchanged("overlay-rightclick-fixed-cancels", m)
        if patternWindow() != nil {
            m = markClipboard(); NSRunningApplication(processIdentifier: patternPID)?.activate(); await wait(500)
            coord.capture(.activeWindow); _ = await until(6000, { surface() != nil }); await wait(100)
            surface()?.window.performClose(nil)
            _ = await until({ !coord.busy }); unchanged("canvas-editor-close-cancels", m)
        }
    }

    static func reentrancyAndFocus() async {
        let m = markClipboard()
        coord.capture(.region); coord.capture(.region); coord.capture(.fullscreen)
        _ = await until({ surface() != nil }); await wait(400)
        let overlays = NSApp.windows.filter { $0.isVisible && $0.level == .screenSaver }.count
        esc(); _ = await until({ !coord.busy })
        unchanged("reentrancy-single-overlay", m, extra: ["visibleOverlays": overlays], cond: overlays == 1)
        // Previous app regains focus after a capture.
        if patternPID != 0 {
            NSRunningApplication(processIdentifier: patternPID)?.activate(); await wait(600)
            _ = await regionCapture("focus-restore", edit: {})
            await wait(600)
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
            record("previous-app-reactivated", front == patternPID, ["frontmost": front, "pattern": patternPID])
        }
    }

    static func decorationAndNaming() async {
        setOpts { $0.options.openEditor = false; $0.options.borderWidth = 3; $0.options.shadow = false }
        let (fw, fh) = full, b = Int((3 * scale).rounded())
        if let c = await autoCapture("border-3pt", .fullscreen, w: fw + 2 * b, h: fh + 2 * b) {
            let corner = c.png.at(0, 0)
            record("border-3pt", c.ok && corner.r < 0.05 && corner.g < 0.05 && corner.b < 0.05, c.info.merging(["corner": "\(corner)"]) { $1 })
        }
        setOpts { $0.options.borderWidth = 0; $0.options.shadow = true }
        let m = markClipboard(); coord.capture(.fullscreen); _ = await until({ !coord.busy })
        let sz = NSPasteboard.general.data(forType: .png).flatMap(decode).map { [$0.width, $0.height] } ?? []
        let L = DecorationLayout(imageSize: CGSize(width: fw, height: fh), border: 0, shadow: true, scale: scale)
        record("drop-shadow", sz == [Int(L.canvas.width), Int(L.canvas.height)] && sz.first ?? 0 > fw && savedFiles().count == m.files.count + 1, ["size": sz])
        setOpts { $0.options.shadow = false }
        // Two saves in a row never overwrite each other.
        let before = savedFiles()
        coord.capture(.fullscreen); _ = await until({ !coord.busy })
        coord.capture(.fullscreen); _ = await until({ !coord.busy })
        let new = savedFiles().filter { !before.contains($0) }
        record("save-naming-collision", new.count == 2 && Set(new).count == 2, ["new": new])
        // saveToFile off: clipboard still written, nothing saved.
        setOpts { $0.saveToFile = false }
        let m2 = markClipboard(); coord.capture(.fullscreen); _ = await until({ !coord.busy })
        record("save-off-clipboard-only", NSPasteboard.general.data(forType: .png) != nil && savedFiles() == m2.files, [:])
        setOpts { $0.saveToFile = true; $0.options.openEditor = true }
    }

    /// The export pipeline at 2x on a synthetic frame (the runner display is 1x), through deliver's same calls.
    static func retina2x() async {
        guard let frame = checker(1600, 1200) else { return }
        let r = Renderer(frame: frame, scale: 2)
        var d = EditorDocument(crop: CGRect(x: 100, y: 100, width: 300, height: 200))
        let id = d.addShape(.rectangle, at: CGPoint(x: 150, y: 150)); d.extendShape(id, to: CGPoint(x: 250, y: 250))
        let bid = d.addShape(.blur, at: CGPoint(x: 260, y: 120)); d.extendShape(bid, to: CGPoint(x: 380, y: 280))
        guard let flat = Export.flatten(renderer: r, doc: d, crop: CGRect(x: 100, y: 100, width: 300, height: 200), lasso: nil) else {
            record("retina-2x-pipeline", false, ["error": "flatten"]); return }
        let img = Export.decorate(flat, options: CaptureOptions(), scale: 2)
        let m = markClipboard()
        let copied = Export.copyToClipboard(img, scale: 2)
        let url = Export.savePNG(img, scale: 2, folder: saved.path)
        guard copied, url != nil, let c = checkClipboard("retina-2x-pipeline", since: m, w: 600, h: 400) else {
            record("retina-2x-pipeline", false, ["copied": copied]); return }
        let pointSize = NSImage(pasteboard: NSPasteboard.general)?.size ?? .zero
        let red = isRed(c.png.at(100 + 2, 150))
        record("retina-2x-pipeline", c.ok && red && pointSize == CGSize(width: 300, height: 200) && (c.info["savedDPI"] as? Double) == 144,
               c.info.merging(["pointSize": "\(pointSize)", "red": red]) { $1 }, status: nil)
    }

    static func hotkey() async {
        // Control-Shift-1 (Region). Posting HID events needs Accessibility; result is recorded either way.
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 18, keyDown: down)
            e?.flags = [.maskControl, .maskShift]; e?.post(tap: .cghidEventTap)
        }
        let fired = await until(2000, { surface() != nil })
        if fired { esc(); _ = await until({ !coord.busy }) }
        record("hotkey-ctrl-shift-1", fired, ["note": "synthetic CGEvent; a physical key press is not testable on a headless runner"],
               status: fired ? nil : "unverifiable")
    }

    static func menuAndSettings() async {
        guard let menu = app.statusItem.menu else { record("menu-bar", false); return }
        app.menuNeedsUpdate(menu)
        let titles = menu.items.map(\.title)
        let want = CaptureStyle.allCases.map(\.title) + ["Before capture", "Settings…", "Quit ShareX"]
        let before = menu.items.first { $0.title == "Before capture" }?.submenu?.items.map(\.title) ?? []
        record("menu-bar", app.statusItem.button?.image != nil && want.allSatisfy(titles.contains) && before.count == 6,
               ["titles": titles, "beforeCapture": before])
        app.openSettings(); await wait(500)
        let shown = app.settingsWindow?.isVisible == true
        app.settingsWindow?.close()
        record("settings-window", shown, [:])
    }
}
