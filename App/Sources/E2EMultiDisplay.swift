#if SHAREX_E2E
import AppKit
import KeyboardShortcuts
import ShareXCore

@MainActor
enum E2EMultiDisplay {
    private typealias Surface = (window: NSWindow, view: EditorView)
    @MainActor private final class Rig {
        var controller: OverlayController!
        var outcomes: [EditorOutcome] = []
        var result: EditorResult? {
            for outcome in outcomes { if case .finished(let result) = outcome { return result } }
            return nil
        }
        init(_ frozen: [FrozenScreen], fullscreen: Bool = false) {
            let bounds = DesktopImageSource(frozen: frozen)!.bounds
            var settings = AppSettings(); settings.options.showMagnifier = false
            controller = OverlayController(frozen: frozen, mode: .rectangle,
                                           preset: fullscreen ? .init(displayID: 0, rect: bounds, desktop: true) : nil,
                                           settings: settings, onStyles: { _ in }) { [weak self] in self?.outcomes.append($0) }
            controller.show()
        }
        var surfaces: [Surface] { controller.e2eSurfaces }
        var session: EditorSession { controller.session! }
        func cancel() { session.cancel() }
    }

    private static func event(_ type: NSEvent.EventType, _ point: CGPoint, from surface: Surface) {
        let local = surface.view.local(point)
        E2E.mouse(type, local, in: surface)
    }
    private static func drag(_ start: CGPoint, _ end: CGPoint, from surface: Surface) {
        event(.leftMouseDown, start, from: surface)
        for i in 1...8 {
            let k = CGFloat(i) / 8
            event(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * k, y: start.y + (end.y - start.y) * k), from: surface)
        }
        event(.leftMouseUp, end, from: surface)
    }
    private static func command(_ title: String, toolbar: ToolbarView) -> Bool {
        guard let button = toolbar.e2eButton(title), button.isEnabled else { return false }
        button.performClick(nil); return true
    }
    private static func seamPoints(from a: CGRect, to b: CGRect, offset: CGSize) -> (CGPoint, CGPoint) {
        let vertical = a.maxY == b.minY || b.maxY == a.minY
        let overlapLeft = max(a.minX, b.minX), overlapRight = min(a.maxX, b.maxX)
        let seamX = overlapLeft + min(100, (overlapRight - overlapLeft) / 4)
        return (CGPoint(x: (vertical ? seamX : a.midX) - offset.width, y: a.midY - offset.height),
                CGPoint(x: (vertical ? seamX : b.midX) + offset.width, y: b.midY + offset.height))
    }
    private static func previewMatches(_ rig: Rig, crop: CGRect, name: String) async -> (ok: Bool, info: [String: Any]) {
        guard let flat = Export.flatten(renderer: rig.session.renderer, doc: rig.session.doc, crop: crop, lasso: nil) else {
            return (false, ["error": "export unavailable"])
        }
        E2EOrientation.writePNG(flat, "\(name)-export.png")
        let expected = E2E.bitmap(flat), scale = rig.session.renderer.scale
        var softwareOK = true, nativeOK = true
        var softwarePanels: [[String: Any]] = [], nativePanels: [[String: Any]] = []
        for (index, surface) in rig.surfaces.enumerated() {
            let other = rig.surfaces[index == 0 ? 1 : 0].view.viewport
            let geometry: [String: Any] = ["panel": index, "viewport": NSStringFromRect(surface.view.viewport),
                "viewBounds": NSStringFromRect(surface.view.bounds), "windowFrame": NSStringFromRect(surface.window.frame),
                "layers": surface.view.subviews.compactMap { child -> [String: Any]? in
                    guard child is FrameView || child is AnnotationsView || child is LiveMarkView else { return nil }
                    return ["type": String(describing: type(of: child)), "frame": NSStringFromRect(child.frame),
                            "bounds": NSStringFromRect(child.bounds), "layerBounds": child.layer.map { NSStringFromRect($0.bounds) } ?? "missing"]
                }]
            if let preview = E2E.snapshotImageLayers(surface.view, scale: scale, name: "\(name)-panel-\(index).png") {
                let result = comparePreview(preview, expected: expected, scale: scale, crop: crop, surface: surface, other: other, native: false)
                softwareOK = result.ok && softwareOK
                softwarePanels.append(geometry.merging(result.info) { _, value in value })
            } else {
                softwareOK = false; softwarePanels.append(geometry.merging(["error": "software snapshot unavailable"]) { _, value in value })
            }
            if let preview = await E2E.snapshotNativeWindow(surface.window, name: "\(name)-native-panel-\(index)") {
                let result = comparePreview(preview, expected: expected, scale: scale, crop: crop, surface: surface, other: other, native: true)
                nativeOK = result.ok && nativeOK
                nativePanels.append(geometry.merging(result.info) { _, value in value })
            } else {
                nativeOK = false; nativePanels.append(geometry.merging(["error": "native snapshot unavailable"]) { _, value in value })
            }
        }
        E2E.record("multidisplay-native-\(name)", nativeOK,
                   ["panels": nativePanels, "crop": NSStringFromRect(crop), "exportSize": [expected.w, expected.h],
                    "stabilityRule": "export pixels within one native pixel of the sample differ by less than 0.02 RGB sum and 0.01 alpha",
                    "minimumSamplesPerPanel": 16, "minimumSamplesWithin64PointsOfSeam": 4])
        return (softwareOK, ["panels": softwarePanels, "crop": NSStringFromRect(crop), "exportSize": [expected.w, expected.h]])
    }

    private static func comparePreview(_ preview: E2E.Bitmap, expected: E2E.Bitmap, scale: CGFloat, crop: CGRect,
                                       surface: Surface, other: CGRect, native: Bool) -> (ok: Bool, info: [String: Any]) {
        let viewport = surface.view.viewport, sampleScale = native ? surface.window.backingScaleFactor : scale
        let intersection = crop.intersection(viewport).insetBy(dx: 5, dy: 5)
        let dimensionsMatch = preview.w == Int(viewport.width * sampleScale) && preview.h == Int(viewport.height * sampleScale)
        let sizeLabelFrame = surface.view.e2eSizeLabelFrame
        var checked = 0, nearSeam = 0, unstable = 0, toolbar = 0, sizeLabel = 0, mismatches = 0
        var firstMismatch: [String: Any]?
        if !intersection.isNull, intersection.width > 0, intersection.height > 0 {
            for y in stride(from: intersection.minY, to: intersection.maxY, by: 17) {
                for x in stride(from: intersection.minX, to: intersection.maxX, by: 17) {
                    let px = Int((x - viewport.minX) * sampleScale), py = Int((y - viewport.minY) * sampleScale)
                    let point = native ? CGPoint(x: viewport.minX + (CGFloat(px) + 0.5) / sampleScale,
                                                y: viewport.minY + (CGFloat(py) + 0.5) / sampleScale) : CGPoint(x: x, y: y)
                    if native && surface.view.e2eToolbar.frame.contains(surface.view.local(point)) { toolbar += 1; continue }
                    if native && sizeLabelFrame?.contains(surface.view.local(point)) == true { sizeLabel += 1; continue }
                    let ex = Int((point.x - crop.minX) * scale), ey = Int((point.y - crop.minY) * scale)
                    let wanted = expected.at(ex, ey)
                    if native {
                        let radius = Int(ceil(scale / sampleScale))
                        var stable = ex >= radius && ey >= radius && ex + radius < expected.w && ey + radius < expected.h
                        if stable {
                            for sy in (ey - radius)...(ey + radius) {
                                for sx in (ex - radius)...(ex + radius) {
                                    let neighbor = expected.at(sx, sy)
                                    stable = stable && abs(neighbor.r - wanted.r) + abs(neighbor.g - wanted.g) + abs(neighbor.b - wanted.b) < 0.02
                                        && abs(neighbor.a - wanted.a) < 0.01
                                }
                            }
                        }
                        if !stable { unstable += 1; continue }
                    }
                    let actual = preview.at(px, py)
                    let matches = abs(actual.r - wanted.r) + abs(actual.g - wanted.g) + abs(actual.b - wanted.b) < 0.04
                        && abs(actual.a - wanted.a) < 0.01
                    checked += 1
                    if (viewport.maxX == other.minX && viewport.maxX - point.x <= 64)
                        || (viewport.minX == other.maxX && point.x - viewport.minX <= 64)
                        || (viewport.maxY == other.minY && viewport.maxY - point.y <= 64)
                        || (viewport.minY == other.maxY && point.y - viewport.minY <= 64) { nearSeam += 1 }
                    if !matches {
                        mismatches += 1
                        if firstMismatch == nil {
                            let fixtureX = (point.x - viewport.minX) * surface.window.backingScaleFactor
                            let fixtureY = (point.y - viewport.minY) * surface.window.backingScaleFactor
                            firstMismatch = ["desktopPoint": NSStringFromPoint(point), "previewPixel": [px, py], "exportPixel": [ex, ey],
                                "checkerCellPixels": 16, "checkerPixelRemainder": [fixtureX.truncatingRemainder(dividingBy: 16), fixtureY.truncatingRemainder(dividingBy: 16)],
                                "actualRGBA": [actual.r, actual.g, actual.b, actual.a], "expectedRGBA": [wanted.r, wanted.g, wanted.b, wanted.a]]
                            firstMismatch?["spotlights"] = surface.view.doc.annotations.filter { $0.kind == .spotlight }.map { annotation -> [String: Any] in
                                let dx = (point.x - annotation.rect.midX) / (annotation.rect.width / 2)
                                let dy = (point.y - annotation.rect.midY) / (annotation.rect.height / 2)
                                return ["rect": NSStringFromRect(annotation.rect), "strength": annotation.style.strength,
                                        "normalizedRadiusSquared": dx * dx + dy * dy, "insideEllipse": dx * dx + dy * dy < 1]
                            }
                        }
                    }
                }
            }
        }
        let valid = dimensionsMatch && mismatches == 0 && checked >= (native ? 16 : 1) && (!native || nearSeam >= 4)
        var info: [String: Any] = ["matches": valid, "previewSize": [preview.w, preview.h], "dimensionsMatch": dimensionsMatch,
            "sampleScale": sampleScale, "exportScale": scale, "checked": checked, "nearSeam": nearSeam,
            "skippedUnstable": unstable, "skippedToolbar": toolbar, "skippedSizeLabel": sizeLabel, "mismatches": mismatches,
            "intersection": NSStringFromRect(intersection), "toolbarFrame": NSStringFromRect(surface.view.e2eToolbar.frame),
            "sizeLabelFrame": sizeLabelFrame.map { NSStringFromRect($0) } ?? "hidden"]
        if let firstMismatch { info["firstMismatch"] = firstMismatch }
        return (valid, info)
    }

    static func run() async {
        let fixtures = NSScreen.screens.filter {
            let id = ScreenCapture.displayID(of: $0)
            return CGDisplayVendorNumber(id) == 505 && CGDisplayModelNumber(id) == 0x5358
        }
        let screens = (fixtures.count >= 2 ? fixtures : NSScreen.screens).sorted { $0.backingScaleFactor < $1.backingScaleFactor }
        E2E.source = "native NSScreen panels, deterministic frozen tiles"
        E2E.record("multidisplay-native-fixtures", screens.count >= 2,
                   ["fixtureDisplays": fixtures.count, "layout": E2E.arg(after: "--multidisplay-layout") ?? "unspecified",
                    "displayFrames": screens.map { NSStringFromRect($0.frame) }, "scales": screens.map(\.backingScaleFactor)])
        guard screens.count >= 2 else { return }
        let frozen = screens.prefix(2).compactMap { screen -> FrozenScreen? in
            guard let image = E2E.checker(Int(screen.frame.width * screen.backingScaleFactor), Int(screen.frame.height * screen.backingScaleFactor)) else { return nil }
            return FrozenScreen(screen: screen, displayID: ScreenCapture.displayID(of: screen), image: image)
        }
        guard frozen.count == 2 else { E2E.record("multidisplay-tile-fixtures", false); return }
        for reversed in [false, true] {
            let rig = Rig(frozen)
            guard rig.surfaces.count == 2 else { E2E.record("multidisplay-panels", false); rig.cancel(); return }
            let a = rig.surfaces[reversed ? 1 : 0], b = rig.surfaces[reversed ? 0 : 1]
            let (p, q) = seamPoints(from: a.view.viewport, to: b.view.viewport, offset: CGSize(width: 100, height: 70))
            let toolbarFrames = rig.surfaces.map { $0.view.e2eToolbar.frame }
            let crop = Geometry.rect(from: p, to: q), tag = reversed ? "reverse" : "forward"
            let chosen = command("Rectangle", toolbar: b.view.e2eToolbar)
            b.view.changeStyle { $0.filled = true; $0.color = .blue }
            let before = rig.session.doc.history.undoStates.count
            drag(q, p, from: b)
            E2E.record("multidisplay-annotation-one-transaction-\(tag)", chosen && rig.session.doc.annotations.count == 1
                       && rig.session.phase == .annotating && rig.session.doc.state.crop == nil && rig.outcomes.isEmpty
                       && rig.session.doc.history.undoStates.count == before + 1
                       && rig.session.doc.annotations.first?.rect == crop)
            E2E.record("multidisplay-annotation-capture-controls-\(tag)", rig.surfaces.allSatisfy {
                let bar = $0.view.e2eToolbar
                return bar.e2eDone.isHidden && !bar.e2eDone.isEnabled
                    && bar.e2eButton("Window")?.isEnabled == false
                    && bar.e2eButton("Crop") == nil
            })
            let undo = command("Undo", toolbar: a.view.e2eToolbar)
            let empty = rig.session.doc.annotations.isEmpty
            let redo = command("Redo", toolbar: b.view.e2eToolbar)
            E2E.record("multidisplay-shared-undo-\(tag)", undo && redo && empty && rig.session.doc.annotations.count == 1)
            let region = command("Region", toolbar: a.view.e2eToolbar)
            event(.leftMouseDown, p, from: a); event(.leftMouseDragged, q, from: a)
            E2E.record("multidisplay-selection-\(tag)", region && rig.session.selectionHole == crop
                       && rig.session.doc.annotations.count == 1 && rig.outcomes.isEmpty
                       && rig.surfaces.allSatisfy { $0.view.phase == .selecting(.rectangle) && !$0.window.ignoresMouseEvents }
                       && a.view.session === b.view.session && a.view.renderer === b.view.renderer)
            let preview = await previewMatches(rig, crop: crop, name: "seam-\(tag)")
            E2E.record("multidisplay-seam-preview-\(tag)", preview.ok, preview.info)
            let finalToolbarFrames = rig.surfaces.map { $0.view.e2eToolbar.frame }
            E2E.record("multidisplay-toolbar-stays-top-\(tag)", toolbarFrames == finalToolbarFrames
                       && rig.surfaces.allSatisfy { $0.view.e2eToolbar.frame.minY == $0.view.safeTop },
                       ["initialFrames": toolbarFrames.map { NSStringFromRect($0) },
                        "finalFrames": finalToolbarFrames.map { NSStringFromRect($0) }])
            let expected = Export.flatten(renderer: rig.session.renderer, doc: rig.session.doc, crop: crop, lasso: nil).map(E2E.bitmap)
            event(.leftMouseUp, q, from: a)
            E2E.record("multidisplay-mouse-release-once-\(tag)", rig.session.phase == .ended && rig.outcomes.count == 1 && rig.result != nil
                       && !a.window.isVisible && !b.window.isVisible)
            event(.leftMouseUp, q, from: a); a.view.finish(); b.view.cancel()
            E2E.record("multidisplay-terminal-commands-once-\(tag)", rig.outcomes.count == 1)
            if let result = rig.result {
                let mark = E2E.markClipboard()
                let copied = Export.copyToClipboard(result.image, scale: result.scale)
                let saved = Export.savePNG(result.image, scale: result.scale, folder: E2E.saved.path)
                if let clip = E2E.checkClipboard("multidisplay-output-\(tag)", since: mark, w: result.image.width, h: result.image.height) {
                    E2E.record("multidisplay-output-\(tag)", copied && saved != nil && clip.ok
                               && expected?.px == E2E.bitmap(result.image).px && clip.png.px == E2E.bitmap(result.image).px
                               && result.lastRegion?.resolve(layout: a.view.renderer.source.layout!) == crop, clip.info)
                }
            }
            rig.cancel()
            let fullscreen = Rig(frozen, fullscreen: true), panels = fullscreen.surfaces
            let posted = E2E.postClick(panels[reversed ? 0 : 1].view.e2eToolbar.e2eDone)
            let mouseFinished = await E2E.until { !fullscreen.outcomes.isEmpty }
            E2E.record("multidisplay-mouse-done-once-\(tag)", posted && mouseFinished && fullscreen.outcomes.count == 1
                       && fullscreen.result != nil && panels.allSatisfy { !$0.window.isVisible })
            fullscreen.cancel()
        }
        await effects(frozen)
        await textAndToolbar(frozen)
        await sparseAndScale()
        await coordinatorFullscreen()
        await E2ELastRegion.run()
        E2E.record("multidisplay-separate-spaces-physical-input", false,
                   ["note": "Virtual displays and native window events do not prove physical mouse routing or separate Spaces."], status: "unverifiable")
    }

    private static func effects(_ frozen: [FrozenScreen]) async {
        for kind in [ShapeKind.blur, .pixelate, .highlighter, .spotlight] {
            let rig = Rig(frozen), surfaces = rig.surfaces
            guard surfaces.count == 2 else { rig.cancel(); continue }
            let a = surfaces[0], b = surfaces[1]
            let (p, q) = seamPoints(from: a.view.viewport, to: b.view.viewport, offset: CGSize(width: 60, height: 60))
            a.view.setTool(.shape(kind)); drag(p, q, from: a)
            let crop = Geometry.rect(from: p, to: q)
            E2E.record("multidisplay-effect-before-selection-\(kind.rawValue)", rig.session.phase == .annotating
                       && rig.session.doc.state.crop == nil && rig.session.doc.annotations.count == 1 && rig.outcomes.isEmpty)
            let preview = await previewMatches(rig, crop: crop, name: "effect-\(kind.rawValue)")
            E2E.record("multidisplay-effect-preview-\(kind.rawValue)", preview.ok, preview.info)
            if kind == .blur || kind == .pixelate {
                a.view.renderer.e2eRejectEffectImage = true
                a.view.changeStyle { $0.strength += 3 }
                let pixels = Export.flatten(renderer: a.view.renderer, doc: a.view.doc, crop: crop, lasso: nil).map(E2E.bitmap)
                let opaque = pixels.map { $0.frac(CGRect(x: 0, y: 0, width: $0.w, height: $0.h)) { $0.r == 0 && $0.g == 0 && $0.b == 0 && $0.a == 1 } == 1 } ?? false
                let failure = await previewMatches(rig, crop: crop, name: "failure-\(kind.rawValue)")
                E2E.record("multidisplay-effect-failure-opaque-\(kind.rawValue)", opaque && failure.ok, failure.info)
            }
            let expected = Export.flatten(renderer: a.view.renderer, doc: a.view.doc, crop: crop, lasso: nil).map(E2E.bitmap)
            let region = command("Region", toolbar: b.view.e2eToolbar)
            drag(q, p, from: b)
            E2E.record("multidisplay-effect-release-\(kind.rawValue)", region && rig.session.phase == .ended
                       && rig.outcomes.count == 1 && rig.result.map { E2E.bitmap($0.image).px == expected?.px } == true
                       && surfaces.allSatisfy { !$0.window.isVisible })
            rig.cancel()
        }
    }

    private static func textAndToolbar(_ frozen: [FrozenScreen]) async {
        let rig = Rig(frozen, fullscreen: true), surfaces = rig.surfaces
        guard surfaces.count == 2 else { rig.cancel(); return }
        let a = surfaces[0], b = surfaces[1], p = CGPoint(x: a.view.viewport.midX, y: a.view.viewport.midY)
        _ = command("Text", toolbar: a.view.e2eToolbar)
        event(.leftMouseDown, p, from: a); event(.leftMouseUp, p, from: a)
        let fields = surfaces.flatMap { E2EEditing.views($0.view).compactMap { $0 as? NSTextField }.filter { $0.isEditable } }
        fields.first?.stringValue = "One shared text transaction"
        _ = command("Crop", toolbar: b.view.e2eToolbar)
        E2E.record("multidisplay-one-text-host-commit", fields.count == 1 && rig.session.doc.annotations.first?.text == "One shared text transaction"
                   && surfaces.allSatisfy { E2EEditing.views($0.view).compactMap { $0 as? NSTextField }.allSatisfy { !$0.isEditable } }
                   && b.window.firstResponder === b.view)
        let crop = rig.session.doc.state.crop, history = rig.session.doc.history.undoStates.count
        for surface in surfaces {
            let bar = surface.view.e2eToolbar
            let point = CGPoint(x: bar.frame.minX + 2, y: bar.frame.midY)
            E2E.mouse(.leftMouseDown, point, in: surface); E2E.mouse(.leftMouseUp, point, in: surface)
        }
        E2E.record("multidisplay-toolbar-background-consumes-input", rig.session.doc.state.crop == crop && rig.session.doc.history.undoStates.count == history)
        for (index, surface) in surfaces.enumerated() { await styleUI(surface, tag: "panel-\(index)") }
        let bar = a.view.e2eToolbar
        bar.fit(maxWidth: 280); bar.setFrameSize(bar.fittingSize); bar.layoutSubtreeIfNeeded()
        E2E.record("multidisplay-narrow-toolbar-done-visible", bar.bounds.width <= 280 && controlsFit(bar)
                   && !bar.e2eDone.isHidden && ["Select", "Crop", "Rectangle", "Ellipse", "Line", "Arrow", "Highlighter", "Blur",
                                               "Pixelate", "Spotlight", "Pen", "Text", "Step marker"].allSatisfy { title in
                       bar.e2eButton(title) != nil
                   })
        E2E.snapshotNativeView(bar, name: "multidisplay-toolbar-narrow")
        rig.cancel()
        let selection = Rig(frozen), chooser = selection.surfaces[0].view.e2eToolbar
        let modes = ["Region", "Freehand", "Window", "Monitor", "Full Desktop"]
        E2E.record("multidisplay-selection-mouse-modes", modes.allSatisfy { title in chooser.e2eButton(title) != nil })
        _ = command("Full Desktop", toolbar: chooser)
        E2E.record("multidisplay-full-desktop-by-mouse", selection.session.phase == .ended && selection.outcomes.count == 1
                   && selection.result?.crop == selection.session.bounds0)
        selection.cancel()
        await E2E.wait(20)
    }

    private static func controlsFit(_ root: NSView) -> Bool {
        let controls = E2EEditing.views(root).compactMap { $0 as? NSControl }.filter { !$0.isHiddenOrHasHiddenAncestor }
        return !controls.isEmpty && controls.allSatisfy { control in
            control.bounds.width > 0 && control.bounds.height > 0
                && root.bounds.contains(control.convert(control.bounds, to: root))
                && !control.visibleRect.isEmpty
        }
    }

    private static func styleUI(_ surface: Surface, tag: String) async {
        let view = surface.view, bar = view.e2eToolbar
        let selected = command("Rectangle", toolbar: bar)
        bar.layoutSubtreeIfNeeded()
        E2E.record("multidisplay-toolbar-bounds-\(tag)", controlsFit(bar) && view.bounds.contains(bar.frame))
        await E2E.snapshotNativeWindow(surface.window, name: "multidisplay-full-ui-\(tag)")
        E2E.snapshotNativeView(bar, name: "multidisplay-toolbar-\(tag)")
        let posted = E2E.postClick(bar.e2eStyle)
        let shown = await E2E.until {
            bar.e2eStyleContents.window.map { $0.isVisible && $0.occlusionState.contains(.visible) } == true
        }
        let contents = bar.e2eStyleContents
        contents.layoutSubtreeIfNeeded()
        let controls = E2EEditing.views(contents).compactMap { $0 as? NSControl }
        let buttons = controls.compactMap { $0 as? NSButton }
        let sliders = controls.compactMap { $0 as? NSSlider }
        let onScreen = contents.window.map { window in NSScreen.screens.contains { $0.frame.contains(window.frame) } } ?? false
        E2E.record("multidisplay-style-visible-\(tag)", selected && posted && shown && onScreen
                   && controlsFit(contents) && controls.allSatisfy { !$0.isHiddenOrHasHiddenAncestor }
                   && buttons.count == 8 && buttons.contains { $0.title == "Reset tool style" } && sliders.count == 3,
                   ["controls": controls.count, "bounds": NSStringFromRect(contents.bounds),
                    "controlFrames": controls.map { NSStringFromRect($0.convert($0.bounds, to: contents)) }])
        guard shown else { bar.closePopover(); return }
        E2E.snapshotNativeView(contents, name: "multidisplay-style-rectangle-\(tag)")

        var colorsWork = true
        for title in ["Blue", "Yellow", "Green", "Red", "Black", "White"] {
            guard let button = buttons.first(where: { $0.title == title }) else { colorsWork = false; continue }
            let clicked = E2E.postClick(button)
            let changed = await E2E.until { view.doc.style(for: .rectangle).color == RGBA.palette[button.tag] }
            colorsWork = colorsWork && clicked && changed
        }
        guard let width = sliders.first(where: { $0.accessibilityLabel() == "Width / size" }),
              let opacity = sliders.first(where: { $0.accessibilityLabel() == "Opacity" }),
              let fill = buttons.first(where: { $0.title == "Fill" }) else {
            E2E.record("multidisplay-style-controls-\(tag)", false); bar.closePopover(); return
        }
        let oldWidth = view.doc.style(for: .rectangle).width
        let widthClicked = E2E.postClick(width, at: CGPoint(x: width.bounds.width * (oldWidth > 20 ? 0.2 : 0.8), y: width.bounds.midY))
        let widthChanged = await E2E.until { abs(view.doc.style(for: .rectangle).width - oldWidth) > 1 }
        let oldOpacity = view.doc.style(for: .rectangle).opacity
        let opacityClicked = E2E.postClick(opacity, at: CGPoint(x: opacity.bounds.width * (oldOpacity < 0.5 ? 0.8 : 0.3), y: opacity.bounds.midY))
        let opacityChanged = await E2E.until { abs(view.doc.style(for: .rectangle).opacity - oldOpacity) > 0.1 }
        let oldFill = view.doc.style(for: .rectangle).filled
        let fillClicked = E2E.postClick(fill)
        let fillChanged = await E2E.until { view.doc.style(for: .rectangle).filled != oldFill }
        E2E.record("multidisplay-style-controls-\(tag)", colorsWork && widthClicked && widthChanged
                   && opacityClicked && opacityChanged && fillClicked && fillChanged)
        bar.closePopover()
        _ = await E2E.until { contents.window?.isVisible != true }

        let blurSelected = command("Blur", toolbar: bar)
        let blurPosted = E2E.postClick(bar.e2eStyle)
        let blurShown = await E2E.until { contents.window?.isVisible == true }
        if let strength = sliders.first(where: { $0.accessibilityLabel() == "Effect strength" }), blurShown {
            E2E.snapshotNativeView(contents, name: "multidisplay-style-blur-\(tag)")
            let oldStrength = view.doc.style(for: .blur).strength
            let clicked = E2E.postClick(strength, at: CGPoint(x: strength.bounds.width * (oldStrength > 45 ? 0.2 : 0.8), y: strength.bounds.midY))
            let changed = await E2E.until { abs(view.doc.style(for: .blur).strength - oldStrength) > 1 }
            E2E.record("multidisplay-style-strength-\(tag)", blurSelected && blurPosted && controlsFit(contents)
                       && strength.isEnabled && !fill.isEnabled && clicked && changed)
        } else { E2E.record("multidisplay-style-strength-\(tag)", false) }
        bar.closePopover()
        let restored = await E2E.until { surface.window.firstResponder === view }
        E2E.record("multidisplay-style-restores-responder-\(tag)", restored)
    }

    private static func sparseAndScale() async {
        guard let one = E2E.checker(800, 600), let two = E2E.checker(1600, 1200),
              let layout = DesktopLayout(displays: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 1),
                                                   .init(id: 2, frame: CGRect(x: 100_000, y: 0, width: 800, height: 600), scale: 2)]),
              let source = DesktopImageSource(layout: layout, images: [one, two]) else { E2E.record("multidisplay-sparse-source", false); return }
        let renderer = Renderer(source: source, scale: 2)
        let session = EditorSession(renderer: renderer, mode: .rectangle, initialCrop: nil, styles: [:], pickRects: [], finishOnPick: false)
        let view = EditorView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), session: session,
                              viewport: source.tiles[0].rect, image: one, showMagnifier: false)
        let window = OverlayWindow(contentRect: CGRect(origin: E2E.screen.frame.origin, size: view.bounds.size),
                                   styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFrontRegardless()
        let surface: Surface = (window, view)
        var outcomes: [EditorOutcome] = []
        session.completion = { outcomes.append($0); window.orderOut(nil) }
        defer {
            session.cancel(); view.releaseResources(); window.orderOut(nil)
            window.contentView = nil; window.close()
        }
        view.setTool(.shape(.pixelate))
        drag(CGPoint(x: 120, y: 330), CGPoint(x: 220, y: 390), from: surface)
        let annotation = session.doc.annotations.first, history = session.doc.history.undoStates.count
        session.chooseSelection(.rectangle)
        drag(CGPoint(x: 50, y: 150), CGPoint(x: 100_750, y: 550), from: surface)
        E2E.record("multidisplay-oversized-editable-feedback", session.phase == .editing && !session.canFinish
                   && session.status?.contains("Use Crop") == true && outcomes.isEmpty && annotation != nil
                   && session.doc.annotations.first == annotation && session.doc.history.undoStates.count == history
                   && Export.flatten(renderer: renderer, doc: session.doc, crop: source.bounds, lasso: nil) == nil)
        session.undo()
        let uncropped = session.phase == .annotating && session.doc.state.crop == nil && session.doc.annotations.isEmpty
        session.redo()
        E2E.record("multidisplay-oversized-undo-redo", uncropped && session.phase == .editing && !session.canFinish
                   && session.doc.annotations.first == annotation && outcomes.isEmpty)
        view.setTool(.crop)
        let recovered = CGRect(x: 100, y: 300, width: 200, height: 120)
        drag(recovered.origin, CGPoint(x: recovered.maxX, y: recovered.maxY), from: surface)
        let retryReady = session.phase == .editing && session.canFinish && session.doc.state.crop == recovered
            && session.doc.annotations.first == annotation && outcomes.isEmpty
        let expected = Export.flatten(renderer: renderer, doc: session.doc, crop: recovered, lasso: nil).map(E2E.bitmap)
        let posted = E2E.postClick(view.e2eToolbar.e2eDone)
        let finished = await E2E.until { !outcomes.isEmpty }
        let delivered = outcomes.first.map { outcome in
            if case .finished(let result) = outcome {
                return result.crop == recovered && result.image.width == 200 && result.image.height == 120
                    && E2E.bitmap(result.image).px == expected?.px
            }
            return false
        } ?? false
        session.finish(); session.cancel()
        E2E.record("multidisplay-oversized-crop-done-recovery", retryReady && posted && finished && delivered
                   && session.phase == .ended && outcomes.count == 1 && !window.isVisible)
        let crop = CGRect(x: 50, y: 50, width: 200, height: 120)
        renderer.setScale(for: crop)
        let small = Export.flatten(renderer: renderer, doc: EditorDocument(), crop: crop, lasso: nil)
        E2E.record("multidisplay-sparse-native-scale-crop", renderer.scale == 1 && small?.width == 200 && small?.height == 120
                   && source.selection(CGRect(x: 1000, y: 20, width: 200, height: 100)) == nil)
        var doc = EditorDocument(crop: crop)
        let id = doc.addShape(.pixelate, at: CGPoint(x: 60, y: 60)); doc.extendShape(id, to: CGPoint(x: 180, y: 140))
        _ = Export.flatten(renderer: renderer, doc: doc, crop: crop, lasso: nil)
        let cached = renderer.e2eCacheBytes > 0
        renderer.setScale(for: source.bounds)
        let cleared = renderer.e2eCacheBytes == 0 && renderer.e2eLiveBytes == 0
        renderer.setScale(for: crop)
        let restored = Export.flatten(renderer: renderer, doc: doc, crop: crop, lasso: nil)
        let fresh = Export.flatten(renderer: Renderer(source: source, scale: 1), doc: doc, crop: crop, lasso: nil)
        E2E.record("multidisplay-scale-cache-transition", cached && cleared && restored.flatMap { r in fresh.map { E2E.bitmap(r).px == E2E.bitmap($0).px } } == true)
        session.cancel()
    }

    private static func coordinatorFullscreen() async {
        let saved = E2E.app.settings.value
        ScreenCapture.e2eFixture = E2E.checker
        E2E.setOpts { $0.options.openEditor = true; $0.options.delaySeconds = 0; $0.playSound = false; $0.saveToFile = false }
        defer { ScreenCapture.e2eFixture = nil; E2E.setOpts { $0 = saved } }
        E2E.coord.capture(.fullscreen)
        let shown = await E2E.until { E2E.coord.overlay != nil }
        let surfaces = E2E.coord.overlay?.e2eSurfaces ?? []
        E2E.record("multidisplay-coordinator-fullscreen-original-displays", shown && surfaces.count == NSScreen.screens.count
                   && surfaces.allSatisfy { $0.window.styleMask.contains(.titled) == false && $0.view.phase == .editing && $0.window.isVisible })
        surfaces.first?.view.cancel()
        _ = await E2E.until { !E2E.coord.busy }
        E2E.setOpts { $0.saveToFile = true; $0.saveFolder = E2E.saved.path }
        let clipboard = E2E.markClipboard()
        E2E.coord.capture(.region)
        let regionShown = await E2E.until { E2E.coord.overlay != nil }
        let all = E2E.coord.overlay?.e2eSurfaces ?? []
        let fixtures = all.filter { surface in
            guard let map = surface.view.renderer.source.layout,
                  let display = map.displays.first(where: { map.placement($0) == surface.view.viewport }) else { return false }
            return CGDisplayVendorNumber(display.id) == 505 && CGDisplayModelNumber(display.id) == 0x5358
        }
        let participating = fixtures.count >= 2 ? fixtures : all
        if regionShown, participating.count >= 2 {
            let a = participating[0], b = participating[1]
            let p = CGPoint(x: a.view.viewport.midX - 80, y: a.view.viewport.midY - 50)
            let q = CGPoint(x: b.view.viewport.midX + 80, y: b.view.viewport.midY + 50)
            a.view.setTool(.shape(.pixelate)); drag(p, q, from: a)
            let region = command("Region", toolbar: b.view.e2eToolbar)
            let crop = Geometry.rect(from: p, to: q)
            drag(q, p, from: b)
            let area = a.view.renderer.pixelArea(crop)
            let delivered = await E2E.until(15_000) { !E2E.coord.busy }
            if let area, let clip = E2E.checkClipboard("multidisplay-coordinator-delivery", since: clipboard, w: area.w, h: area.h) {
                E2E.record("multidisplay-coordinator-delivery", region && delivered && clip.ok
                           && a.view.phase == .ended && all.allSatisfy { !$0.window.isVisible }
                           && (E2E.app.settings.value.lastRegion?.participants?.count ?? 0) >= 2, clip.info)
            } else { E2E.record("multidisplay-coordinator-delivery", false) }
        } else { E2E.record("multidisplay-coordinator-region", false) }
        E2E.coord.overlay?.e2eSurfaces.first?.view.cancel()
        E2E.record("multidisplay-single-factory-binding", Hotkeys.commands.filter { $0.name.initialShortcut != nil }.map(\.style) == [.region])
    }
}
#endif
