// Compiled only into CI test builds (SWIFT_ACTIVE_COMPILATION_CONDITIONS += SHAREX_E2E); never shipped.
#if SHAREX_E2E
import AppKit
@preconcurrency import ScreenCaptureKit
import ShareXCore

/// Magnifier probe. The frozen frame encodes each pixel's position (red = px % 16, green = py % 16, in 1/15 steps),
/// so every loupe cell read back from the overlay window says which frame pixel it shows. Hovering at a point must
/// show the 15×15 pixels around the pixel under the cursor, upright, at 8x; moving the mouse must update it.
@MainActor
enum E2ELoupe {
    static let size = CGSize(width: 300, height: 240), sc: CGFloat = 2

    static func fixture() -> CGImage? {
        let w = Int(size.width * sc), h = Int(size.height * sc)
        guard let g = Imaging.context(width: w, height: h, flipped: true) else { return nil }   // y-down pixels
        for y in 0..<h { for x in 0..<w {
            g.setFillColor(CGColor(srgbRed: CGFloat(x % 16) / 15, green: CGFloat(y % 16) / 15, blue: 0.5, alpha: 1))
            g.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        return g.makeImage()
    }

    /// Loupe frame for cursor `p` (mirrors ChromeView.layoutMagnifier placement).
    static func loupe(_ p: CGPoint) -> CGRect {
        let side = ChromeView.n * ChromeView.zoom
        var o = CGPoint(x: p.x + 20, y: p.y + 20)
        if o.x + side > size.width { o.x = p.x - 20 - side }
        if o.y + side + 18 > size.height { o.y = p.y - 20 - side - 18 }
        o.x = min(max(o.x, 0), max(0, size.width - side)); o.y = min(max(o.y, 0), max(0, size.height - side - 18))
        return CGRect(origin: o, size: CGSize(width: side, height: side))
    }

    /// Fraction of the 15×15 cells whose colour decodes to the expected frame pixel, plus the centre cell decode.
    static func check(_ m: E2E.Bitmap, cursor p: CGPoint) -> (ok: Bool, info: [String: Any]) {
        let kx = Double(m.w) / size.width, ky = Double(m.h) / size.height
        let L = loupe(p), z = ChromeView.zoom, half = Int(ChromeView.n - 1) / 2
        let cx = Int((p.x * sc).rounded(.down)), cy = Int((p.y * sc).rounded(.down))
        var good = 0, total = 0, centre: [Int] = []
        for j in 0..<Int(ChromeView.n) { for i in 0..<Int(ChromeView.n) {
            let vx = L.minX + (CGFloat(i) + 0.5) * z, vy = L.minY + (CGFloat(j) + 0.5) * z
            let c = m.at(Int(Double(vx) * kx), Int(Double(vy) * ky))
            let rx = Int((c.r * 15).rounded()), gy = Int((c.g * 15).rounded())
            let sx = cx - half + i, sy = cy - half + j
            let inside = sx >= 0 && sy >= 0 && sx < Int(size.width * sc) && sy < Int(size.height * sc)
            let ex = (sx % 16 + 16) % 16, ey = (sy % 16 + 16) % 16
            total += 1
            if inside ? (rx == ex && gy == ey && abs(c.b - 0.5) < 0.1) : (c.r < 0.1 && c.g < 0.1 && c.b < 0.1) { good += 1 }
            if i == half && j == half { centre = [rx, gy, cx % 16, cy % 16] }
        } }
        let f = Double(good) / Double(total)
        // The centre cell itself carries the 1-pt red marker border; its inside must still be the pixel under the cursor.
        return (f > 0.9, ["cursor": [p.x, p.y], "loupe": [L.minX, L.minY, L.width, L.height], "cellsMatching": f,
                          "centreDecoded_rx_gy_expected": centre, "px": [m.w, m.h]])
    }

    static func capture(_ w: NSWindow, _ v: NSView, _ name: String) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let sw = content.windows.first(where: { $0.windowID == CGWindowID(w.windowNumber) }) {
                let bs = w.backingScaleFactor
                let cfg = SCStreamConfiguration(); cfg.width = Int(size.width * bs); cfg.height = Int(size.height * bs); cfg.showsCursor = false
                cfg.colorSpaceName = CGColorSpace.sRGB
                let shot = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: sw), configuration: cfg)
                E2EOrientation.writePNG(shot, name)
                return shot
            }
        } catch { NSLog("E2E loupe SCK: %@", error.localizedDescription) }
        // Fallback: Core Animation render of the layer tree.
        guard let layer = v.layer else { return nil }
        let pw = Int(size.width * sc), ph = Int(size.height * sc)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: Imaging.colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(ph)); ctx.scaleBy(x: sc, y: -sc)
        layer.render(in: ctx)
        let img = ctx.makeImage(); if let img { E2EOrientation.writePNG(img, name) }
        return img
    }

    /// What the loupe must show for cursor `p` (view points) on a frame of `scale` px/pt: visible, the
    /// "X: Y:" label naming the pixel under the cursor, and the sampled square centred on that pixel.
    static func loupeState(_ v: EditorView, cursor p: CGPoint, scale s: CGFloat) -> (ok: Bool, info: [String: Any]) {
        let l = v.e2eLoupe
        let want = " X: \(Int(p.x * s))  Y: \(Int(p.y * s)) "
        // Centre of the visible source square, in source pixels (only exact away from the image edge).
        let cx = (l.contentsRect.midX * l.source.width), cy = (l.contentsRect.midY * l.source.height)
        let centreOK = abs(cx - (floor(p.x * s) + 0.5)) <= 1 && abs(cy - (floor(p.y * s) + 0.5)) <= 1
        let ok = l.visible && l.label == want && centreOK && v.bounds.contains(l.frame)
        return (ok, ["visible": l.visible, "label": l.label, "want": want, "centre": [cx, cy], "centreOK": centreOK,
                     "frame": "\(l.frame)", "scale": s])
    }

    /// Skeptic: reopen through the real path (coordinator -> OverlayController.show -> syncMouse), no
    /// test-side syncMouse, 100 times, with another app frontmost and the cursor parked before the hotkey.
    static func reopen() async {
        var shown = 0, fails: [[String: Any]] = [], activeAny = false
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        if E2E.patternPID != 0 { NSRunningApplication(processIdentifier: E2E.patternPID)?.activate(); await E2E.wait(500) }
        let n = 100
        let wasOn = E2E.app.settings.value.options.showMagnifier
        E2E.setOpts { $0.options.showMagnifier = true }
        defer { E2E.setOpts { $0.options.showMagnifier = wasOn } }
        for k in 0..<n {
            let sf = E2E.screen.frame
            // Away from the edges so the centre cell is a full interior sample.
            let p = CGPoint(x: 60 + Double(k * 37 % Int(sf.width - 120)), y: 60 + Double(k * 53 % Int(sf.height - 120)))
            CGWarpMouseCursorPosition(CGPoint(x: sf.minX + p.x, y: primaryH - (sf.maxY - p.y)))
            await E2E.wait(40)
            E2E.coord.capture(.region)
            guard await E2E.until(3000, { E2E.surface() != nil }), let s = E2E.surface() else { fails.append(["k": k, "error": "no overlay"]); continue }
            activeAny = activeAny || NSApp.isActive
            // First frame only: no event is sent, nothing calls syncMouse but the app.
            let r = loupeState(s.view, cursor: p, scale: s.view.renderer.scale)
            if r.ok { shown += 1 } else if fails.count < 3 { fails.append(r.info.merging(["k": k]) { $1 }) }
            E2E.esc(); _ = await E2E.until({ !E2E.coord.busy })
        }
        E2E.record("loupe-reopen-100x-real-path", shown == n, ["shown": shown, "of": n, "appEverActive": activeAny, "fails": fails])
    }

    static func run() async {
        guard let img = fixture() else { E2E.record("loupe", false, ["error": "no fixture"]); return }
        let v = EditorView(frame: CGRect(origin: .zero, size: size), renderer: Renderer(frame: img, scale: sc), mode: .rectangle,
                           initialCrop: nil, styles: [:], showMagnifier: true, pickRects: [], finishOnPick: false)
        let screen = E2E.screen.frame
        let w = OverlayWindow(contentRect: CGRect(x: screen.minX + 120, y: screen.maxY - 120 - size.height, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.level = .screenSaver; w.sharingType = .readOnly
        // As OverlayController.add/show do for the real overlay.
        w.acceptsMouseMovedEvents = true
        w.contentView = v; NSApp.activate(); w.orderFrontRegardless(); w.makeKeyAndOrderFront(nil); w.makeFirstResponder(v)
        await E2E.wait(300)
        var info: [String: Any] = ["isKey": w.isKeyWindow, "appActive": NSApp.isActive, "trackingAreas": v.trackingAreas.count]
        // Real HID moves first: the path the user's mouse takes (needs the PostEvent grant; recorded either way).
        for (name, p) in [("hid", CGPoint(x: 60, y: 50)), ("hid2", CGPoint(x: 101, y: 80))] {
            let sp = w.convertPoint(toScreen: v.convert(p, to: nil))
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: sp.x, y: primaryH - sp.y),
                    mouseButton: .left)?.post(tap: .cghidEventTap)
            await E2E.wait(400)
            if let shot = await capture(w, v, "loupe-\(name).png") { info[name] = check(E2E.bitmap(shot), cursor: p).info }
        }
        func send(_ t: NSEvent.EventType, _ p: CGPoint) {
            if let e = NSEvent.mouseEvent(with: t, location: v.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { w.sendEvent(e) }
        }
        var ok = true
        // Hover (before any drag), then move, then a drag near the bottom-right edge (loupe flips to the other side).
        let steps: [(String, NSEvent.EventType, CGPoint)] = [("hover", .mouseMoved, CGPoint(x: 60, y: 50)),
                                                             ("moved", .mouseMoved, CGPoint(x: 101.5, y: 80)),
                                                             ("cornerTopLeft", .mouseMoved, CGPoint(x: 1.5, y: 1.5)),
                                                             ("cornerBottomRight", .mouseMoved, CGPoint(x: 298.5, y: 238.5)),
                                                             ("cornerTopRight", .mouseMoved, CGPoint(x: 298.5, y: 1.5)),
                                                             ("dragEdge", .leftMouseDragged, CGPoint(x: 250, y: 200))]
        for (i, (name, type, p)) in steps.enumerated() {
            if type == .leftMouseDragged { send(.leftMouseDown, CGPoint(x: 150, y: 120)) }
            let t0 = DispatchTime.now().uptimeNanoseconds
            send(type, p)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            w.displayIfNeeded(); CATransaction.flush()
            await E2E.wait(400)
            guard let shot = await capture(w, v, i == 0 ? "loupe.png" : "loupe-\(name).png") else { ok = false; info[name] = "no capture"; continue }
            var r = check(E2E.bitmap(shot), cursor: p).info; r["eventMs"] = ms
            ok = ok && check(E2E.bitmap(shot), cursor: p).ok
            info[name] = r
        }
        send(.leftMouseUp, CGPoint(x: 250, y: 200))
        v.releaseResources(); w.orderOut(nil); w.contentView = nil; w.close()
        // Pace commits at display ticks so WindowServer queue backpressure does not dominate hover cost.
        do {
            let v2 = EditorView(frame: CGRect(origin: .zero, size: size), renderer: Renderer(frame: img, scale: sc), mode: .rectangle,
                                initialCrop: nil, styles: [:], showMagnifier: true, pickRects: [], finishOnPick: false)
            let w2 = OverlayWindow(contentRect: w.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w2.isReleasedWhenClosed = false; w2.contentView = v2; w2.orderFrontRegardless()
            let vsync = E2EPerf.Vsync(w2)
            defer { vsync.stop() }
            var t: [Double] = [], cpu: [Double] = []
            var retina = (n: 0, ok: 0, fails: [[String: Any]]())
            for k in 0..<300 {
                let p = CGPoint(x: 5 + Double(k % 290), y: 5 + Double((k * 7) % 230))
                guard let e = NSEvent.mouseEvent(with: .mouseMoved, location: v2.convert(p, to: nil), modifierFlags: [],
                                                 timestamp: 0, windowNumber: w2.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 0, pressure: 0) else { continue }
                guard await vsync.next() >= 0 else { ok = false; break }
                let t0 = DispatchTime.now().uptimeNanoseconds, c0 = E2EPerf.cpuNow()
                v2.mouseMoved(with: e); CATransaction.flush()
                cpu.append(E2EPerf.cpuNow() - c0)
                t.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                // Skeptic (b): the runner is 1x, so check the 2x frozen frame by state: pixel label and sampled centre.
                if p.x > 10, p.x < size.width - 10, p.y > 10, p.y < size.height - 10, k % 10 == 0 {
                    let r = loupeState(v2, cursor: p, scale: sc)
                    retina.n += 1; if r.ok { retina.ok += 1 } else if retina.fails.count < 3 { retina.fails.append(r.info) }
                }
            }
            let timing = E2EPerf.stats(t)
            info["hoverMs"] = timing
            info["hoverCPUMs"] = E2EPerf.stats(cpu)
            info["hoverTimingScope"] = "Debug mouseMoved + CATransaction.flush, paced at display ticks; excludes capture and GPU rendering"
            ok = ok && t.count == 300 && (timing["p95"] ?? .infinity) < 2
            E2E.record("loupe-2x-frame-state", retina.n > 10 && retina.ok == retina.n,
                       ["checked": retina.n, "ok": retina.ok, "frameScale": sc, "windowBacking": w2.backingScaleFactor,
                        "fails": retina.fails, "note": "2x frozen frame simulated; the runner display is 1x"])
            v2.releaseResources(); w2.orderOut(nil); w2.contentView = nil; w2.close()
        }
        E2E.record("loupe", ok, info)
        await reopen()
    }
}
#endif
