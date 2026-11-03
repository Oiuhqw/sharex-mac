// Compiled only into CI test builds (SWIFT_ACTIVE_COMPILATION_CONDITIONS += SHAREX_E2E); never shipped.
#if SHAREX_E2E
import AppKit
import ImageIO
@preconcurrency import ScreenCaptureKit
import ShareXCore

/// On-screen orientation probe. The exported PNGs come from Renderer, not from what the overlay shows, so this
/// checks the overlay window itself: a frame with red (top) / green (middle) / blue (bottom) bands is frozen, a
/// region is dragged in the top band, and the window's real pixels (SCK window capture with sharingType
/// .readOnly; CALayer render of the content view as a second source) must show red on top, blue at the bottom,
/// and an undimmed hole exactly where the selection is.
@MainActor
enum E2EOrientation {
    static let size = CGSize(width: 300, height: 240), sc: CGFloat = 2
    static let hole = CGRect(x: 20, y: 10, width: 120, height: 60)   // view points, top-left origin

    static func bands() -> CGImage? {
        let w = Int(size.width * sc), h = Int(size.height * sc)
        guard let g = Imaging.context(width: w, height: h, flipped: true) else { return nil }   // y-down pixels
        let cols = [CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
                    CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)]
        for (i, c) in cols.enumerated() { g.setFillColor(c); g.fill(CGRect(x: 0, y: h * i / 3, width: w, height: h / 3 + 1)) }
        return g.makeImage()
    }

    typealias C = (r: Double, g: Double, b: Double, a: Double)
    /// Samples in view points (top-left origin), read from a bitmap whose row 0 is the top.
    static func check(_ m: E2E.Bitmap) -> (ok: Bool, info: [String: Any]) {
        let kx = Double(m.w) / size.width, ky = Double(m.h) / size.height
        func at(_ x: CGFloat, _ y: CGFloat) -> C { m.at(Int(Double(x) * kx), Int(Double(y) * ky)) }
        func fmt(_ c: C) -> [Double] { [c.r, c.g, c.b].map { ($0 * 100).rounded() / 100 } }
        let inHole = at(hole.midX, hole.midY), topOut = at(220, 40), mid = at(220, 120), bottom = at(150, 210)
        // Undimmed red in the hole; red dimmed by the 35 % black scrim outside it; green middle; blue bottom.
        let holeBright = inHole.r > 0.85 && inHole.g < 0.2 && inHole.b < 0.2
        let topDim = topOut.r > 0.45 && topOut.r < 0.8 && topOut.g < 0.2 && topOut.b < 0.2
        let midGreen = mid.g > 0.45 && mid.r < 0.2 && mid.b < 0.2
        let bottomBlue = bottom.b > 0.45 && bottom.r < 0.2 && bottom.g < 0.2
        // Hole edges: just inside vs just outside each edge.
        let edgeIn = [at(hole.minX + 4, hole.midY), at(hole.maxX - 4, hole.midY), at(hole.midX, hole.minY + 4), at(hole.midX, hole.maxY - 4)]
        let edgeOut = [at(hole.minX - 4, hole.midY), at(hole.maxX + 4, hole.midY), at(hole.midX, max(1, hole.minY - 4)), at(hole.midX, hole.maxY + 4)]
        let edges = zip(edgeIn, edgeOut).allSatisfy { $0.r > 0.85 && $1.r < 0.8 }
        let ok = holeBright && topDim && midGreen && bottomBlue && edges
        return (ok, ["hole": fmt(inHole), "topOutside": fmt(topOut), "middle": fmt(mid), "bottom": fmt(bottom),
                     "holeBright": holeBright, "topDimmed": topDim, "middleGreen": midGreen, "bottomBlue": bottomBlue,
                     "holeEdgesAligned": edges, "px": [m.w, m.h]])
    }

    static func writePNG(_ img: CGImage, _ name: String) {
        let url = E2E.out.appendingPathComponent(name)
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
    }

    static func run() async {
        guard let img = bands() else { E2E.record("onscreen-orientation", false, ["error": "no fixture"]); return }
        let v = EditorView(frame: CGRect(origin: .zero, size: size), renderer: Renderer(frame: img, scale: sc), mode: .rectangle,
                           initialCrop: nil, styles: [:], showMagnifier: false, pickRects: [], finishOnPick: false)
        let screen = E2E.screen.frame
        let w = OverlayWindow(contentRect: CGRect(x: screen.minX + 120, y: screen.maxY - 120 - size.height, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.level = .screenSaver; w.sharingType = .readOnly
        w.contentView = v; w.orderFrontRegardless()
        func send(_ t: NSEvent.EventType, _ p: CGPoint) {
            if let e = NSEvent.mouseEvent(with: t, location: v.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { w.sendEvent(e) }
        }
        // Drag a region (no mouse-up): the selection phase's dim hole follows the drag.
        send(.leftMouseDown, hole.origin)
        send(.leftMouseDragged, CGPoint(x: hole.midX, y: hole.midY))
        send(.leftMouseDragged, CGPoint(x: hole.maxX, y: hole.maxY))
        w.displayIfNeeded(); CATransaction.flush()
        await E2E.wait(400)

        var info: [String: Any] = ["selection": [hole.minX, hole.minY, hole.width, hole.height]]
        var verdict: Bool?
        // 1. WindowServer pixels of the overlay window.
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let sw = content.windows.first(where: { $0.windowID == CGWindowID(w.windowNumber) }) {
                // Capture at the window's real backing scale (1x on the CI display); a larger buffer leaves the window
                // unscaled in its top-left corner and the samples land on empty pixels.
                let bs = w.backingScaleFactor
                let cfg = SCStreamConfiguration(); cfg.width = Int(size.width * bs); cfg.height = Int(size.height * bs); cfg.showsCursor = false
                cfg.colorSpaceName = CGColorSpace.sRGB
                let shot = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: sw), configuration: cfg)
                writePNG(shot, "onscreen-orientation.png")
                let r = check(E2E.bitmap(shot)); info["windowServer"] = r.info; verdict = r.ok
            } else { info["windowServer"] = "window not in SCShareableContent" }
        } catch { info["windowServer"] = "SCK: \(error.localizedDescription)" }
        // 2. The view's layer tree rendered by Core Animation (what is composited, independent of TCC).
        if let layer = v.layer {
            let pw = Int(size.width * sc), ph = Int(size.height * sc)
            if let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: Imaging.colorSpace,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                // CGBitmapContext is y-up; a flipped view's layer tree renders y-down, so flip the probe context
                // (without this the HUD text comes out mirrored, i.e. the inversion is the probe's, not the app's).
                if v.isFlipped { ctx.translateBy(x: 0, y: CGFloat(ph)); ctx.scaleBy(x: sc, y: -sc) } else { ctx.scaleBy(x: sc, y: sc) }
                layer.render(in: ctx)
                if let li = ctx.makeImage() {
                    writePNG(li, "onscreen-orientation-layer.png")
                    if verdict == nil { writePNG(li, "onscreen-orientation.png") }
                    let r = check(E2E.bitmap(li)); info["layerRender"] = r.info
                    if verdict == nil { verdict = r.ok }
                }
            }
        }
        send(.leftMouseUp, CGPoint(x: hole.maxX, y: hole.maxY))
        w.orderOut(nil); w.contentView = nil
        E2E.record("onscreen-orientation", verdict ?? false, info)
    }
}
#endif
