#if SHAREX_E2E
import AppKit
import ShareXCore

@MainActor
enum E2EEllipseHit {
    static func run() async {
        for scale in [CGFloat(1), CGFloat(2)] { await run(scale: scale) }
    }

    private static func run(scale: CGFloat) async {
        let name = "ellipse-painted-stroke-select-delete-\(Int(scale))x"
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 360)
        let width = Int(frame.width * scale), height = Int(frame.height * scale)
        guard let context = Imaging.context(width: width, height: height, flipped: true) else {
            E2E.record(name, false, ["error": "fixture allocation failed"]); return
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            E2E.record(name, false, ["error": "fixture image failed"]); return
        }
        let view = EditorView(frame: frame, renderer: Renderer(frame: image, scale: scale), mode: .rectangle,
                              initialCrop: frame, styles: [.ellipse: ShapeStyle(width: 40)],
                              showMagnifier: false, pickRects: [], finishOnPick: false)
        let window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        defer { view.releaseResources(); window.orderOut(nil); window.contentView = nil }
        let surface = (window: window as NSWindow, view: view)
        func key(_ code: UInt16, _ characters: String) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                  isARepeat: false, keyCode: code) else { continue }
                window.sendEvent(event)
            }
        }
        func click(_ point: CGPoint) {
            E2E.mouse(.leftMouseDown, point, in: surface)
            E2E.mouse(.leftMouseUp, point, in: surface)
        }
        func exported() -> E2E.Bitmap? {
            Export.flatten(renderer: view.renderer, doc: view.doc, crop: frame, lasso: nil).map(E2E.bitmap)
        }
        func displayed(_ suffix: String) -> E2E.Bitmap? {
            window.displayIfNeeded()
            CATransaction.flush()
            guard let layer = view.layer,
                  let output = Imaging.context(width: width, height: height, flipped: false) else { return nil }
            output.translateBy(x: 0, y: CGFloat(height))
            output.scaleBy(x: scale, y: -scale)
            layer.render(in: output)
            guard let image = output.makeImage() else { return nil }
            E2EOrientation.writePNG(image, "\(name)-\(suffix).png")
            return E2E.bitmap(image)
        }
        let point = CGPoint(x: 1100, y: 121)
        let px = Int(point.x * scale), py = Int(point.y * scale)
        key(14, "e")
        E2E.mouse(.leftMouseDown, CGPoint(x: 100, y: 100), in: surface)
        E2E.mouse(.leftMouseDragged, CGPoint(x: 1100, y: 104), in: surface)
        E2E.mouse(.leftMouseUp, CGPoint(x: 1100, y: 104), in: surface)
        let drawn = view.doc.annotations.count == 1
            && view.doc.selected?.rect == CGRect(x: 100, y: 100, width: 1000, height: 4)
            && view.doc.selected?.style.width == 40
        let id = view.doc.selectedID
        key(9, "v")
        click(CGPoint(x: 50, y: 200))
        let deselected = view.doc.selectedID == nil
        await E2E.wait(80)
        let exportPainted = exported().map { E2E.isRed($0.at(px, py)) } ?? false
        let viewPainted = displayed("painted").map { E2E.isRed($0.at(px, py)) } ?? false
        click(point)
        let selected = id != nil && view.doc.selectedID == id
        key(51, "\u{7f}")
        let deleted = view.doc.annotations.isEmpty && view.doc.selectedID == nil
        let exportRestored = exported()?.px == E2E.bitmap(image).px
        await E2E.wait(80)
        let viewRestored = displayed("deleted").map {
            let color = $0.at(px, py)
            return color.r > 0.95 && color.g > 0.95 && color.b > 0.95
        } ?? false
        E2E.record(name, drawn && deselected && exportPainted && viewPainted && selected && deleted && exportRestored && viewRestored,
                   ["fixture": "solid-white", "nativeWindowEvents": true, "scale": scale,
                    "drawn": drawn, "deselectedBeforeClick": deselected, "exportPixelPainted": exportPainted,
                    "layerPixelPainted": viewPainted, "selectedByPaintedPixel": selected, "deletedByKey": deleted,
                    "exportRestored": exportRestored, "layerPixelRestored": viewRestored])
    }
}
#endif
