#if SHAREX_E2E
import AppKit
import ShareXCore

@MainActor
enum E2EEditorRegression {
    private typealias Surface = (window: NSWindow, view: EditorView)
    private static let size = CGSize(width: 300, height: 320)
    private static let crop = CGRect(x: 140, y: 120, width: 320, height: 120)

    static func run() async {
        let screen = E2E.screen.frame
        let frames = (0..<2).map { CGRect(x: screen.minX + 40 + CGFloat($0) * size.width,
                                          y: screen.maxY - 60 - size.height, width: size.width, height: size.height) }
        guard let layout = DesktopLayout(displays: frames.enumerated().map { .init(id: UInt32($0.offset + 1), frame: $0.element, scale: 1) }),
              let red = image(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
              let blue = image(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)),
              let source = DesktopImageSource(layout: layout, images: [red, blue]) else {
            E2E.record("editor-regression-fixture", false); return
        }
        for mode in [SelectionMode.rectangle, .lasso] {
            await gestures(mode, source: source, layout: layout)
        }
    }

    private static func image(_ color: CGColor) -> CGImage? {
        guard let context = Imaging.context(width: Int(size.width), height: Int(size.height), flipped: true) else { return nil }
        context.setFillColor(color); context.fill(CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    private static func gestures(_ mode: SelectionMode, source: DesktopImageSource, layout: DesktopLayout) async {
        let tag = mode == .rectangle ? "rectangle" : "lasso"
        let session = EditorSession(renderer: Renderer(source: source, scale: 1), mode: mode, initialCrop: nil,
                                    styles: [:], pickRects: [], finishOnPick: false)
        let surfaces: [Surface] = layout.displays.enumerated().map { index, display in
            let view = EditorView(frame: CGRect(origin: .zero, size: size), session: session, viewport: layout.placement(display),
                                  image: source.tiles[index].image, showMagnifier: false)
            let window = OverlayWindow(contentRect: display.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.acceptsMouseMovedEvents = true
            window.contentView = view; window.orderFrontRegardless()
            return (window, view)
        }
        var outcomes: [EditorOutcome] = []
        session.completion = { outcomes.append($0) }
        defer {
            session.cancel()
            for surface in surfaces {
                surface.view.releaseResources(); surface.window.orderOut(nil)
                surface.window.contentView = nil; surface.window.close()
            }
        }
        let bar = surfaces[0].view.e2eToolbar
        var controlsFit = true
        let widths: [CGFloat] = [292, 412, 292, 412, 292]
        for maximum in widths {
            bar.fit(maxWidth: maximum); bar.setFrameSize(bar.fittingSize); bar.layoutSubtreeIfNeeded()
            let controls: [NSView] = [bar.e2eTools, bar.e2eMore, bar.e2eStyle, bar.e2eDone, bar.e2eCancel]
            controlsFit = controlsFit && bar.frame.width <= maximum && controls.allSatisfy {
                let rect = bar.convert($0.bounds, from: $0)
                return !$0.isHiddenOrHasHiddenAncestor && rect.width > 0 && rect.height > 0 && bar.bounds.contains(rect)
            }
        }
        surfaces[0].view.refresh()
        E2E.record("editor-compact-toolbar-transitions-\(tag)", controlsFit && !bar.e2eDone.isEnabled && bar.e2eCancel.isEnabled,
                   ["transitions": 4, "fixture": "two native windows on one display"])

        let start = CGPoint(x: 460, y: 120)
        let points = mode == .rectangle ? [CGPoint(x: 140, y: 240)]
            : [CGPoint(x: 140, y: 120), CGPoint(x: 140, y: 240), CGPoint(x: 460, y: 240), start]
        let owner = surfaces[1]
        func send(_ type: NSEvent.EventType, _ point: CGPoint) {
            E2E.mouse(type, CGPoint(x: point.x - 300, y: point.y), in: owner)
        }
        send(.leftMouseDown, start)
        for point in points { send(.leftMouseDragged, point) }
        if mode == .rectangle {
            E2E.record("editor-rectangle-drag-projections", session.selectionHole == crop && previewsMatch(surfaces, name: "rectangle-drag"))
        } else {
            E2E.record("editor-lasso-drag-points", session.lasso == [start] + points)
        }
        send(.leftMouseUp, points.last!)
        let flattened = Export.flatten(renderer: session.renderer, doc: session.doc, crop: crop, lasso: session.lasso)
        let outputMatches = flattened.map {
            let pixels = E2E.bitmap($0), left = pixels.at(50, 60), right = pixels.at(250, 60)
            return pixels.w == 320 && pixels.h == 120 && left.r > 0.98 && left.b < 0.02 && left.a > 0.98
                && right.b > 0.98 && right.r < 0.02 && right.a > 0.98
        } ?? false
        E2E.record("editor-\(tag)-selection-projections", session.phase == .editing && session.doc.state.crop == crop
                   && surfaces.allSatisfy { $0.view.e2eSizeLabel == "320 × 120" }
                   && previewsMatch(surfaces, name: tag) && outputMatches)
        E2E.snapshotNativeView(surfaces[0].view, name: "editor-\(tag)-compact-toolbar")
        let posted = E2E.postClick(mode == .rectangle ? bar.e2eCancel : bar.e2eDone)
        let completed = await E2E.until { !outcomes.isEmpty }
        let expectedOutcome = outcomes.first.map {
            switch $0 {
            case .cancelled: return mode == .rectangle
            case .finished(let result):
                return mode == .lasso && result.crop == crop && result.image.width == 320 && result.image.height == 120
                    && flattened.map { E2E.bitmap($0).px == E2E.bitmap(result.image).px } == true
            case .pickedWindow: return false
            }
        } ?? false
        E2E.record("editor-compact-mouse-\(mode == .rectangle ? "cancel" : "done")", posted && completed && outcomes.count == 1 && expectedOutcome)
    }

    private static func previewsMatch(_ surfaces: [Surface], name: String) -> Bool {
        var valid = true
        for (index, surface) in surfaces.enumerated() {
            surface.window.displayIfNeeded(); CATransaction.flush()
            guard let context = Imaging.context(width: Int(size.width), height: Int(size.height), flipped: true),
                  let layer = surface.view.layer else { return false }
            layer.render(in: context)
            guard let image = context.makeImage() else { return false }
            E2EOrientation.writePNG(image, "editor-\(name)-projection-\(index).png")
            let pixels = E2E.bitmap(image)
            let inside = pixels.at(index == 0 ? 200 : 100, 180), outside = pixels.at(index == 0 ? 200 : 100, 280)
            let bright = index == 0 ? inside.r : inside.b, dim = index == 0 ? outside.r : outside.b
            valid = valid && bright > 0.95 && dim > 0.60 && dim < 0.70
        }
        return valid
    }
}
#endif
