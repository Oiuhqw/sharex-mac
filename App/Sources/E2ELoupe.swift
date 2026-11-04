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

    /// Opens a fresh overlay 20 times with the cursor already parked over it and no event sent: the loupe must be on
    /// the first frame every time, whether or not the app is active (the CI app is a background app, never key).
    static func reopen(_ img: CGImage) async {
        var shown = 0, fails: [[String: Any]] = []
        let screen = E2E.screen.frame
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        for k in 0..<20 {
            let p = CGPoint(x: 40 + Double(k * 11 % 220), y: 30 + Double(k * 17 % 180))
            let frame = CGRect(x: screen.minX + 120, y: screen.maxY - 120 - size.height, width: size.width, height: size.height)
            CGWarpMouseCursorPosition(CGPoint(x: frame.minX + p.x, y: primaryH - (frame.maxY - p.y)))
            await E2E.wait(150)
            let v = EditorView(frame: CGRect(origin: .zero, size: size), renderer: Renderer(frame: img, scale: sc), mode: .rectangle,
                               initialCrop: nil, styles: [:], showMagnifier: true, pickRects: [], finishOnPick: false)
            let w = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false; w.level = .screenSaver; w.sharingType = .readOnly; w.acceptsMouseMovedEvents = true
            w.contentView = v; w.orderFrontRegardless(); v.syncMouse()
            w.displayIfNeeded(); CATransaction.flush()
            await E2E.wait(250)
            if let shot = await capture(w, v, k == 0 ? "loupe-reopen.png" : "loupe-reopen-last.png") {
                let r = check(E2E.bitmap(shot), cursor: p)
                if r.ok { shown += 1 } else { fails.append(r.info) }
            }
            w.orderOut(nil); w.contentView = nil
        }
        E2E.record("loupe-reopen-20x", shown == 20, ["shown": shown, "of": 20, "appActive": NSApp.isActive, "fails": fails.prefix(3).map { $0 }])
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
        w.orderOut(nil); w.contentView = nil
        // Hover cost: 300 moves straight into the view (refresh + layer updates, no capture).
        do {
            let v2 = EditorView(frame: CGRect(origin: .zero, size: size), renderer: Renderer(frame: img, scale: sc), mode: .rectangle,
                                initialCrop: nil, styles: [:], showMagnifier: true, pickRects: [], finishOnPick: false)
            let w2 = OverlayWindow(contentRect: w.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w2.isReleasedWhenClosed = false; w2.contentView = v2; w2.orderFrontRegardless()
            var t: [Double] = []
            for k in 0..<300 {
                let p = CGPoint(x: 5 + Double(k % 290), y: 5 + Double((k * 7) % 230))
                guard let e = NSEvent.mouseEvent(with: .mouseMoved, location: v2.convert(p, to: nil), modifierFlags: [],
                                                 timestamp: 0, windowNumber: w2.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 0, pressure: 0) else { continue }
                let t0 = DispatchTime.now().uptimeNanoseconds
                v2.mouseMoved(with: e); CATransaction.flush()
                t.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            t.sort()
            let p50 = t[t.count / 2], p95 = t[Int(Double(t.count) * 0.95)]
            info["hoverMs"] = ["p50": p50, "p95": p95, "max": t.last ?? 0, "n": t.count]
            ok = ok && p95 < 2
            w2.orderOut(nil); w2.contentView = nil
        }
        E2E.record("loupe", ok, info)
        await reopen(img)
    }
}
#endif
