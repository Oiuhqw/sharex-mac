#if SHAREX_E2E
import AppKit
import ShareXCore

@MainActor
enum E2EPrecision {
    static func run() {
        for scale in [CGFloat(1), CGFloat(2), CGFloat(2040) / 1400] { run(scale: scale) }
    }

    private static func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], in view: EditorView) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                          windowNumber: view.window?.windowNumber ?? 0, context: nil,
                                          characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else { return }
        view.keyDown(with: event)
    }

    private static func run(scale: CGFloat) {
        let name = String(format: "%.4gx", Double(scale))
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        guard let image = E2E.checker(Int(frame.width * scale), Int(frame.height * scale)) else {
            E2E.record("precision-setup-\(name)", false); return
        }
        let renderer = Renderer(frame: image, scale: scale)
        let initial = CGRect(x: 100.25, y: 100.75, width: 400.5, height: 300.5)
        let view = EditorView(frame: frame, renderer: renderer, mode: .rectangle, initialCrop: initial,
                              styles: [:], showMagnifier: true, pickRects: [], finishOnPick: false)
        let window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.acceptsMouseMovedEvents = true
        window.contentView = view; window.orderFrontRegardless()
        window.makeFirstResponder(view)
        defer { view.releaseResources(); window.orderOut(nil); window.contentView = nil }
        let surface = (window: window as NSWindow, view: view)
        view.setTool(.crop)
        guard let original = renderer.pixelArea(initial),
              let flat = Export.flatten(renderer: renderer, doc: view.doc, crop: initial, lasso: nil),
              let encoded = Export.encode(flat, scale: scale), let png = E2E.decode(encoded.png), let tiff = E2E.decode(encoded.tiff) else {
            E2E.record("precision-fractional-export-\(name)", false); return
        }
        E2E.record("precision-fractional-export-\(name)", flat.width == original.w && flat.height == original.h
                   && png.width == original.w && png.height == original.h && tiff.width == original.w && tiff.height == original.h
                   && view.e2eSizeLabel == "\(original.w) × \(original.h)")
        var expected = original
        let operations: [(UInt16, NSEvent.ModifierFlags, Int, Int, Bool)] = [
            (124, [], 1, 0, false), (125, [.shift], 0, 10, false),
            (123, [.option], -1, 0, true), (126, [.option, .shift], 0, -10, true)
        ]
        var accurate = true
        for (code, flags, dx, dy, resize) in operations {
            key(code, flags: flags, in: view)
            expected = expected.adjusted(dx: dx, dy: dy, resizing: resize, width: image.width, height: image.height)
            accurate = accurate && view.doc.state.crop == expected.points(scale: scale)
        }
        E2E.record("precision-key-steps-\(name)", accurate && view.doc.history.undoStates.count == operations.count)
        let adjustedImage = Export.flatten(renderer: renderer, doc: view.doc, crop: expected.points(scale: scale), lasso: nil)
        let sourceCrop = image.cropping(to: expected.cgRect)
        E2E.record("precision-key-output-pixels-\(name)", adjustedImage.flatMap { actual in
            sourceCrop.map { E2E.bitmap(actual).px == E2E.bitmap($0).px }
        } == true)
        for _ in operations { view.undo() }
        let restored = view.doc.state.crop == initial
        for _ in operations { view.redo() }
        E2E.record("precision-key-undo-redo-\(name)", restored && view.doc.state.crop == expected.points(scale: scale))

        let start = CGPoint(x: floor(650 * scale) / scale, y: floor(450 * scale) / scale)
        let end = CGPoint(x: start.x + 1 / scale, y: start.y + 1 / scale)
        E2E.mouse(.leftMouseDown, start, in: surface)
        E2E.mouse(.leftMouseDragged, end, in: surface)
        E2E.mouse(.leftMouseUp, end, in: surface)
        let one = view.doc.state.crop.flatMap { renderer.pixelArea($0) }
        E2E.record("precision-one-pixel-crop-\(name)", one?.w == 1 && one?.h == 1 && view.e2eSizeLabel == "1 × 1")
        E2E.mouse(.mouseMoved, end, in: surface)
        E2E.record("precision-crop-loupe-\(name)", view.e2eLoupe.visible)

        for kind in [ShapeKind.rectangle, .blur, .pixelate] {
            view.setTool(.shape(kind))
            if kind == .rectangle { view.changeStyle { $0.filled = true; $0.color = .black; $0.opacity = 1 } }
            E2E.mouse(.leftMouseDown, CGPoint(x: 250, y: 250), in: surface)
            E2E.mouse(.leftMouseDragged, CGPoint(x: 330, y: 330), in: surface)
            E2E.mouse(.leftMouseUp, CGPoint(x: 330, y: 330), in: surface)
            view.setTool(.crop)
            let count = view.e2eAnnotationSyncCount
            E2E.mouse(.mouseMoved, CGPoint(x: 300, y: 290), in: surface)
            let concealed = !view.e2eLoupe.visible
            E2E.mouse(.mouseMoved, CGPoint(x: 100, y: 500), in: surface)
            E2E.record("precision-protected-loupe-\(kind.rawValue)-\(name)", concealed && view.e2eLoupe.visible
                       && view.e2eAnnotationSyncCount == count)
            view.undo()
        }
        view.releaseResources()
        E2E.record("precision-editor-release-\(name)", renderer.e2eLiveBytes == 0 && renderer.e2eCacheBytes == 0
                   && view.e2eLiveLayerBytes == 0 && !view.e2eLoupe.visible)
    }
}
#endif
