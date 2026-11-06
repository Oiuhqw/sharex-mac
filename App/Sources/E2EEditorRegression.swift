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
        for finish in [false, true] { await compactMouse(red, finish: finish) }
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
        var transitions: [[String: Any]] = []
        let widths: [CGFloat] = [292, 412, 292, 412, 292]
        for maximum in widths {
            bar.fit(maxWidth: maximum)
            let fitted = bar.fittingSize
            bar.setFrameSize(fitted); bar.layoutSubtreeIfNeeded()
            let measured = toolbarGeometry(bar, maximum: maximum)
            controlsFit = measured.ok && controlsFit
            await E2E.wait(20)
            surfaces[0].window.displayIfNeeded(); CATransaction.flush()
            transitions.append(["maximumWidth": maximum, "requestedSize": NSStringFromSize(fitted),
                                "immediate": measured.info, "settled": toolbarGeometry(bar, maximum: maximum).info])
        }
        surfaces[0].view.refresh()
        let doneHidden = bar.e2eDone.isHidden && !bar.e2eDone.isEnabled, cancelEnabled = bar.e2eCancel.isEnabled
        E2E.record("editor-compact-toolbar-transitions-\(tag)", controlsFit && doneHidden && cancelEnabled,
                   ["transitions": transitions, "controlsFit": controlsFit, "doneHidden": doneHidden, "cancelEnabled": cancelEnabled,
                    "fixture": "two native windows on one display"])

        let start = CGPoint(x: 460, y: 120)
        let points = mode == .rectangle ? [CGPoint(x: 140, y: 240)]
            : [CGPoint(x: 140, y: 120), CGPoint(x: 140, y: 240), CGPoint(x: 460, y: 240), start]
        let owner = surfaces[1]
        func send(_ type: NSEvent.EventType, _ point: CGPoint) {
            E2E.mouse(type, CGPoint(x: point.x - 300, y: point.y), in: owner)
        }
        owner.view.setTool(.shape(.rectangle)); owner.view.changeStyle { $0.filled = true; $0.color = .black }
        send(.leftMouseDown, CGPoint(x: 340, y: 150)); send(.leftMouseDragged, CGPoint(x: 260, y: 170))
        send(.leftMouseUp, CGPoint(x: 260, y: 170))
        E2E.record("editor-\(tag)-annotate-before-selection", session.phase == .annotating
                   && session.doc.state.crop == nil && session.doc.annotations.count == 1 && outcomes.isEmpty)
        session.chooseSelection(mode)
        send(.leftMouseDown, start)
        for point in points { send(.leftMouseDragged, point) }
        let preview = previewsMatch(surfaces, name: "\(tag)-drag", brightInside: mode == .rectangle)
        if mode == .rectangle {
            E2E.record("editor-rectangle-drag-projections", session.selectionHole == crop && preview.ok,
                       ["selectionHole": session.selectionHole.map(NSStringFromRect) ?? "nil", "expectedCrop": NSStringFromRect(crop),
                        "cropMatches": session.selectionHole == crop, "preview": preview.info])
        } else {
            E2E.record("editor-lasso-drag-points", session.lasso == [start] + points && preview.ok,
                       ["actual": session.lasso?.map { NSStringFromPoint($0) } ?? [], "expected": ([start] + points).map { NSStringFromPoint($0) },
                        "preview": preview.info])
        }
        let labels = surfaces.map { $0.view.e2eSizeLabel }
        let labelsMatch = mode == .lasso || labels.allSatisfy { $0 == "320 × 120" }
        let native = await E2E.snapshotNativeWindow(surfaces[0].window, name: "editor-\(tag)-compact-toolbar")
        let nativeCheck = native.map { projection($0, index: 0, brightInside: mode == .rectangle) }
        E2E.record("editor-\(tag)-native-projection", nativeCheck?.ok == true, nativeCheck?.info ?? ["error": "no native window image"])
        let expected = Export.flatten(renderer: session.renderer, doc: session.doc, crop: crop, lasso: session.lasso).map(E2E.bitmap)
        send(.leftMouseUp, points.last!)
        let result = outcomes.first.flatMap { outcome -> EditorResult? in
            if case .finished(let result) = outcome { return result }
            return nil
        }
        var outputInfo: [String: Any] = ["available": result != nil]
        let outputMatches = result.map {
            let pixels = E2E.bitmap($0.image), left = pixels.at(50, 60), right = pixels.at(250, 60), mark = pixels.at(160, 40)
            outputInfo["size"] = [pixels.w, pixels.h]; outputInfo["expectedSize"] = [320, 120]
            outputInfo["leftRGBA"] = rgba(left); outputInfo["rightRGBA"] = rgba(right); outputInfo["annotationRGBA"] = rgba(mark)
            return pixels.w == 320 && pixels.h == 120 && left.r > 0.98 && left.b < 0.02 && left.a > 0.98
                && right.b > 0.98 && right.r < 0.02 && right.a > 0.98
                && mark.r < 0.02 && mark.g < 0.02 && mark.b < 0.02 && mark.a > 0.98 && expected?.px == pixels.px
        } ?? false
        let phaseMatches = session.phase == .ended && outcomes.count == 1, cropMatches = result?.crop == crop
        E2E.record("editor-\(tag)-selection-projections", phaseMatches && cropMatches && labelsMatch && preview.ok && outputMatches,
                   ["phaseMatches": phaseMatches, "phase": String(describing: session.phase), "cropMatches": cropMatches,
                    "crop": session.doc.state.crop.map(NSStringFromRect) ?? "nil", "expectedCrop": NSStringFromRect(crop),
                    "labelsMatch": labelsMatch, "labels": labels, "preview": preview.info,
                    "outputMatches": outputMatches, "output": outputInfo])
        send(.leftMouseUp, points.last!); session.finish(); session.cancel()
        E2E.record("editor-\(tag)-release-once", session.phase == .ended && outcomes.count == 1 && result != nil)
    }

    private static func compactMouse(_ image: CGImage, finish: Bool) async {
        var outcomes: [EditorOutcome] = []
        var settings = AppSettings(); settings.options.showMagnifier = false
        let controller = OverlayController(canvas: image, scale: 1, screen: E2E.screen, title: "Compact toolbar",
                                           settings: settings, onStyles: { _ in }) { outcomes.append($0) }
        controller.show()
        defer { controller.session?.cancel() }
        guard let surface = controller.e2eSurfaces.first else { E2E.record("editor-compact-mouse-fixture", false); return }
        let bar = surface.view.e2eToolbar
        bar.fit(maxWidth: 292); bar.setFrameSize(bar.fittingSize); bar.layoutSubtreeIfNeeded()
        let fits = toolbarGeometry(bar, maximum: 292).ok && !bar.e2eDone.isHidden && bar.e2eDone.isEnabled
        E2E.snapshotNativeView(bar, name: "editor-compact-\(finish ? "done" : "cancel")-toolbar")
        let posted = E2E.postClick(finish ? bar.e2eDone : bar.e2eCancel)
        let completed = await E2E.until { !outcomes.isEmpty }
        let expectedOutcome = outcomes.first.map {
            switch $0 {
            case .cancelled: return !finish
            case .finished(let result):
                return finish && result.image.width == image.width && result.image.height == image.height
                    && E2E.bitmap(image).px == E2E.bitmap(result.image).px
            case .pickedWindow: return false
            }
        } ?? false
        E2E.record("editor-compact-mouse-\(finish ? "done" : "cancel")", fits && posted && completed && outcomes.count == 1
                   && expectedOutcome && !surface.window.isVisible,
                   ["fits": fits, "posted": posted, "completed": completed, "outcomes": outcomes.count, "expectedOutcome": expectedOutcome])
    }

    private static func toolbarGeometry(_ bar: ToolbarView, maximum: CGFloat) -> (ok: Bool, info: [String: Any]) {
        let controls: [(String, NSControl)] = [("Tool", bar.e2eTools), ("More", bar.e2eMore), ("Style", bar.e2eStyle),
                                              ("Done", bar.e2eDone), ("Cancel", bar.e2eCancel)]
        var valid = bar.frame.width <= maximum
        let geometry: [[String: Any]] = controls.map { name, control in
            let rect = bar.convert(control.bounds, from: control), visible = !control.isHiddenOrHasHiddenAncestor
            let contained = bar.bounds.contains(rect), nonempty = rect.width > 0 && rect.height > 0
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let hit = bar.hitTest(bar.convert(center, to: bar.superview))
            let hitsControl = hit.map { $0 === control || $0.isDescendant(of: control) } ?? false
            valid = valid && ((visible && contained && nonempty) || (name == "Done" && !visible && !control.isEnabled))
            return ["name": name, "frameInToolbar": NSStringFromRect(rect), "visibleRect": NSStringFromRect(control.visibleRect),
                    "visible": visible, "contained": contained, "nonempty": nonempty, "enabled": control.isEnabled,
                    "hitPointInToolbar": NSStringFromPoint(center), "hitsControl": hitsControl,
                    "hitView": hit.map { String(describing: type(of: $0)) } ?? "nil"]
        }
        return (valid, ["fits": valid, "frame": NSStringFromRect(bar.frame), "bounds": NSStringFromRect(bar.bounds),
                        "fittingSize": NSStringFromSize(bar.fittingSize), "visibleRect": NSStringFromRect(bar.visibleRect), "controls": geometry])
    }

    private static func rgba(_ pixel: E2EOrientation.C) -> [Double] { [pixel.r, pixel.g, pixel.b, pixel.a] }

    private static func projection(_ pixels: E2E.Bitmap, index: Int, brightInside: Bool) -> (ok: Bool, info: [String: Any]) {
        let x = Int(CGFloat(index == 0 ? 200 : 100) * CGFloat(pixels.w) / size.width)
        let inside = pixels.at(x, Int(180 * CGFloat(pixels.h) / size.height))
        let outside = pixels.at(x, Int(280 * CGFloat(pixels.h) / size.height))
        let bright = index == 0 ? inside.r : inside.b, dim = index == 0 ? outside.r : outside.b
        let brightMatches = brightInside ? bright > 0.95 : bright > 0.60 && bright < 0.70
        let dimMatches = dim > 0.60 && dim < 0.70
        return (brightMatches && dimMatches, ["index": index, "size": [pixels.w, pixels.h],
                                              "insideRGBA": rgba(inside), "outsideRGBA": rgba(outside),
                                              "brightMatches": brightMatches, "dimMatches": dimMatches])
    }

    private static func previewsMatch(_ surfaces: [Surface], name: String, brightInside: Bool) -> (ok: Bool, info: [String: Any]) {
        var valid = true
        var samples: [[String: Any]] = []
        for (index, surface) in surfaces.enumerated() {
            guard let pixels = E2E.snapshotImageLayers(surface.view, scale: 1, name: "editor-\(name)-projection-\(index).png", includeChrome: true) else {
                valid = false; samples.append(["index": index, "error": "no isolated layer image"]); continue
            }
            let result = projection(pixels, index: index, brightInside: brightInside)
            samples.append(result.info); valid = result.ok && valid
        }
        return (valid, ["matches": valid, "source": "isolated image and chrome layers", "surfaces": samples])
    }
}
#endif
