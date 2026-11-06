#if SHAREX_E2E
import AppKit
import ShareXCore

@MainActor
enum E2EAnnotateFirst {
    static func run() async {
        let settings = E2E.app.settings.value
        defer { E2E.setOpts { $0 = settings } }
        E2E.setOpts {
            $0.options = CaptureOptions(); $0.options.showMagnifier = true
            $0.toolStyles = [:]; $0.saveToFile = true; $0.saveFolder = E2E.saved.path; $0.playSound = false
        }
        for tab in [true, false] { await annotated(tab: tab) }
        await windowPickAfterRedo()
        await undoCropToAnnotations()
        await plainRelease()
        await invalidLasso()
        await cancelled()
    }

    private static func unchanged(_ mark: (change: Int, files: [String])) -> Bool {
        NSPasteboard.general.changeCount == mark.change && NSPasteboard.general.string(forType: .string) == "e2e-sentinel"
            && E2E.savedFiles() == mark.files
    }

    private static func windowPickAfterRedo() async {
        let name = "annotate-first-window-pick-after-redo", mark = E2E.markClipboard()
        let openEditor = E2E.app.settings.value.options.openEditor
        E2E.setOpts { $0.options.openEditor = false }
        defer { E2E.setOpts { $0.options.openEditor = openEditor } }
        guard let target = E2E.patternWindow() else {
            E2E.record(name, false, ["error": "no window target"]); return
        }
        E2E.coord.capture(.region)
        guard await E2E.until({ E2E.surface() != nil }), let surface = E2E.surface(),
              let source = surface.view.renderer.source.sample(E2E.C, scale: E2E.scale, maximumPixels: Imaging.maximumPixels) else {
            E2E.record(name, false, ["error": "no region overlay"]); return
        }
        let view = surface.view
        let fixture = E2EEditing.Session(mark: mark, window: surface.window, view: view, original: E2E.bitmap(source))
        var checks = E2EEditing.tool("Blur", in: fixture)
        E2E.drag(CGPoint(x: 150, y: 150), CGPoint(x: 300, y: 250))
        let annotated = view.doc.state, expected = E2EEditing.image(fixture)
        checks = annotated.annotations.count == 1 && unchanged(mark) && checks
        checks = E2EEditing.button("Undo", in: fixture) && checks
        checks = view.doc.annotations.isEmpty && view.session.canPickWindow && checks
        checks = E2EEditing.tool("Window", in: fixture) && checks
        checks = view.phase == .selecting(.pickWindow) && checks
        checks = E2EEditing.button("Redo", in: fixture) && checks
        checks = view.phase == .selecting(.pickWindow) && view.doc.state == annotated && !view.session.canPickWindow && checks
        let rect = Geometry.cocoaToDisplayTopLeft(target.frame, screenFrame: E2E.screen.frame)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        E2E.mouse(.mouseMoved, point, in: surface)
        checks = view.session.hover != nil && checks
        E2E.click(point)
        let rejected = view.phase == .annotating && view.doc.state == annotated && surface.window.isVisible
            && E2E.coord.busy && unchanged(mark)
        guard rejected else {
            E2E.record(name, false, ["setup": checks, "windowPickRejected": rejected])
            view.cancel(); _ = await E2E.until { !E2E.coord.busy }; return
        }
        await finishRegion(name, fixture, expected: expected, checks: checks,
                           info: ["windowPickRejected": rejected, "annotationPreserved": view.doc.state == annotated])
    }

    private static func undoCropToAnnotations() async {
        let name = "annotate-first-undo-crop-tool", mark = E2E.markClipboard()
        E2E.setOpts { $0.options.openEditor = true }
        E2E.coord.capture(.region)
        guard await E2E.until({ E2E.surface() != nil }), let surface = E2E.surface(),
              let source = surface.view.renderer.source.sample(E2E.C, scale: E2E.scale, maximumPixels: Imaging.maximumPixels) else {
            E2E.record(name, false, ["error": "no region overlay"]); return
        }
        let view = surface.view
        let fixture = E2EEditing.Session(mark: mark, window: surface.window, view: view, original: E2E.bitmap(source))
        var checks = E2EEditing.tool("Blur", in: fixture)
        E2E.drag(CGPoint(x: 150, y: 150), CGPoint(x: 300, y: 250))
        let annotated = view.doc.state, expected = E2EEditing.image(fixture)
        E2E.drag(CGPoint(x: 340, y: 140), CGPoint(x: 400, y: 220))
        checks = view.doc.annotations.count == 2 && E2EEditing.tool("Monitor", in: fixture) && checks
        E2E.click(CGPoint(x: 300, y: 300))
        checks = view.phase == .editing && view.doc.state.crop != nil && unchanged(mark) && checks
        checks = E2EEditing.tool("Crop", in: fixture) && checks
        checks = view.tool == .crop && E2EEditing.button("Undo", in: fixture) && checks
        let restored = view.phase == .annotating && view.doc.state == annotated && view.tool == .select
            && view.e2eToolbar.e2eButton("Crop") == nil && view.e2eToolbar.e2eDone.isHidden
        E2E.drag(CGPoint(x: 340, y: 280), CGPoint(x: 400, y: 340))
        let noHiddenCrop = view.doc.state == annotated && view.doc.history.canRedo && unchanged(mark)
            && surface.window.isVisible && E2E.coord.busy
        await finishRegion(name, fixture, expected: expected, checks: checks && restored && noHiddenCrop,
                           info: ["undoRestoredAnnotations": restored, "dragDidNotCreateCrop": noHiddenCrop])
    }

    private static func finishRegion(_ name: String, _ fixture: E2EEditing.Session, expected: E2E.Bitmap?,
                                     checks: Bool, info: [String: Any]) async {
        let selected = E2EEditing.tool("Region", in: fixture)
        E2E.drag(E2E.C.origin, CGPoint(x: E2E.C.maxX, y: E2E.C.maxY))
        let finished = await E2E.until { !E2E.coord.busy }
        guard let clip = E2E.checkClipboard(name, since: fixture.mark, w: E2E.cw, h: E2E.ch) else { return }
        let blur = E2E.diffFrac(clip.png, fixture.original,
                               CGRect(x: E2E.px(60), y: E2E.px(60), width: E2E.px(130), height: E2E.px(80)))
        E2E.record(name, checks && selected && finished && clip.ok && blur > 0.15 && expected?.px == clip.png.px
                   && fixture.view.phase == .ended && !fixture.window.isVisible,
                   clip.info.merging(info) { $1 }.merging(["blurChangedFraction": blur, "finalRegionMatches": expected?.px == clip.png.px]) { $1 })
    }

    private static func annotated(tab: Bool) async {
        let name = "annotate-first-\(tab ? "tab" : "menu")", mark = E2E.markClipboard()
        E2E.coord.capture(.region)
        guard await E2E.until({ E2E.surface() != nil }), let surface = E2E.surface(),
              let frame = surface.view.renderer.source.sample(E2E.C, scale: E2E.scale, maximumPixels: Imaging.maximumPixels) else {
            E2E.record(name, false, ["error": "no region overlay"]); return
        }
        let view = surface.view, session = view.session
        let fixture = E2EEditing.Session(mark: mark, window: surface.window, view: view, original: E2E.bitmap(frame))
        var checks = view.phase == .selecting(.rectangle) && view.e2eToolbar.e2eDone.isHidden
            && view.e2eToolbar.e2eButton("Crop") == nil
        checks = E2EEditing.tool("Blur", in: fixture) && checks
        E2E.drag(CGPoint(x: 80, y: 140), CGPoint(x: 220, y: 220))
        checks = view.phase == .annotating && view.doc.state.crop == nil && unchanged(mark) && checks
        session.chooseSelection(.pickWindow)
        checks = view.phase == .annotating && !session.canPickWindow
            && view.e2eToolbar.e2eButton("Window")?.isEnabled == false && checks
        checks = E2EEditing.tool("Pixelate", in: fixture) && checks
        E2E.drag(CGPoint(x: 260, y: 140), CGPoint(x: 390, y: 220))
        checks = E2EEditing.tool("Rectangle", in: fixture) && checks
        view.changeStyle { $0.filled = true; $0.color = .red; $0.opacity = 1 }
        E2E.drag(CGPoint(x: 440, y: 260), CGPoint(x: 560, y: 330))
        E2E.drag(CGPoint(x: 520, y: 350), CGPoint(x: 580, y: 390))
        let outsideID = view.doc.selectedID
        view.undo(); checks = view.doc.annotations.count == 3 && checks
        view.redo(); checks = view.doc.annotations.count == 4 && checks
        checks = E2EEditing.tool("Text", in: fixture) && checks
        E2E.click(CGPoint(x: 140, y: 280))
        let text = tab ? "Tab commits text" : "Region commits text"
        let field = E2EEditing.views(view).compactMap { $0 as? NSTextField }.first { $0.isEditable }
        field?.stringValue = text
        checks = field != nil && unchanged(mark) && checks
        if tab { E2EEditing.key(48, "\t", in: fixture) }
        else { checks = E2EEditing.tool("Region", in: fixture) && checks }
        checks = view.phase == .selecting(.rectangle) && view.doc.annotations.count == 5
            && view.doc.annotations.last?.text == text && session.editingTextID == nil && unchanged(mark) && checks
        E2E.mouse(.mouseMoved, CGPoint(x: 170, y: 180), in: surface)
        checks = !view.e2eLoupe.visible
            && view.subviews.contains { $0 is AnnotationsView && !$0.isHidden } && checks

        var withoutOutside = view.doc
        withoutOutside.selectedID = outsideID; withoutOutside.deleteSelected()
        let expected = Export.flatten(renderer: view.renderer, doc: withoutOutside, crop: E2E.C, lasso: nil).map(E2E.bitmap)
        E2E.drag(CGPoint(x: 120, y: 120), CGPoint(x: 180, y: 120))
        let invalidRejected = view.phase == .selecting(.rectangle) && view.doc.state.crop == nil && unchanged(mark)
        E2E.mouse(.leftMouseDown, E2E.C.origin, in: surface)
        E2E.mouse(.leftMouseDragged, CGPoint(x: 350, y: 300), in: surface)
        checks = unchanged(mark) && view.phase == .selecting(.rectangle) && checks
        let endpoint = CGPoint(x: E2E.C.maxX, y: E2E.C.maxY)
        E2E.mouse(.leftMouseUp, endpoint, in: surface)
        E2E.mouse(.leftMouseUp, endpoint, in: surface)
        let finished = await E2E.until { !E2E.coord.busy }
        guard let clip = E2E.checkClipboard(name, since: mark, w: E2E.cw, h: E2E.ch) else { return }
        let blur = E2E.diffFrac(clip.png, fixture.original, CGRect(x: E2E.px(10), y: E2E.px(50), width: E2E.px(100), height: E2E.px(60)))
        let pixelate = E2E.diffFrac(clip.png, fixture.original, CGRect(x: E2E.px(170), y: E2E.px(50), width: E2E.px(110), height: E2E.px(60)))
        let textVisible = clip.png.frac(CGRect(x: E2E.px(40), y: E2E.px(180), width: E2E.px(200), height: E2E.px(30)), E2E.isRed) > 0.02
        let pixels = blur > 0.15 && pixelate > 0.15 && textVisible && E2E.isRed(clip.png.at(E2E.px(380), E2E.px(190)))
            && expected?.px == clip.png.px
        let delivered = NSPasteboard.general.changeCount, files = E2E.savedFiles()
        view.finish(); view.cancel()
        E2E.record(name, checks && invalidRejected && finished && clip.ok && pixels && view.phase == .ended
                   && !surface.window.isVisible && NSPasteboard.general.changeCount == delivered && E2E.savedFiles() == files,
                   clip.info.merging(["noIntermediateOutput": checks, "invalidRegionRetry": invalidRejected,
                                      "blurChangedFraction": blur, "pixelateChangedFraction": pixelate,
                                      "textPixelsVisible": textVisible, "outsideCropClipped": expected?.px == clip.png.px]) { $1 })
    }

    private static func cancelled() async {
        let name = "annotate-first-escape-no-output", mark = E2E.markClipboard()
        E2E.coord.capture(.region)
        guard await E2E.until({ E2E.surface() != nil }), let surface = E2E.surface() else {
            E2E.record(name, false, ["error": "no region overlay"]); return
        }
        surface.view.setTool(.shape(.pixelate))
        E2E.drag(CGPoint(x: 140, y: 140), CGPoint(x: 300, y: 250))
        let annotated = surface.view.phase == .annotating && surface.view.doc.annotations.count == 1 && unchanged(mark)
        E2E.esc()
        let finished = await E2E.until { !E2E.coord.busy }
        E2E.unchanged(name, mark, cond: annotated && finished && !surface.window.isVisible)
    }

    private static func plainRelease() async {
        let name = "annotate-first-plain-release-endpoint", mark = E2E.markClipboard()
        E2E.coord.capture(.region)
        guard await E2E.until({ E2E.surface() != nil }), let surface = E2E.surface(),
              let source = surface.view.renderer.source.sample(E2E.C, scale: E2E.scale, maximumPixels: Imaging.maximumPixels) else {
            E2E.record(name, false, ["error": "no region overlay"]); return
        }
        E2E.mouse(.leftMouseDown, E2E.C.origin, in: surface)
        E2E.mouse(.leftMouseUp, CGPoint(x: E2E.C.maxX, y: E2E.C.maxY), in: surface)
        let finished = await E2E.until { !E2E.coord.busy }
        if let clip = E2E.checkClipboard(name, since: mark, w: E2E.cw, h: E2E.ch) {
            E2E.record(name, finished && clip.ok && clip.png.px == E2E.bitmap(source).px
                       && surface.view.phase == .ended && !surface.window.isVisible, clip.info)
        }
    }

    private static func invalidLasso() async {
        let name = "annotate-first-invalid-lasso-retry", mark = E2E.markClipboard()
        E2E.coord.capture(.freehand)
        guard await E2E.until({ E2E.surface() != nil }), let surface = E2E.surface() else {
            E2E.record(name, false, ["error": "no freehand overlay"]); return
        }
        E2E.drag([CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 200), CGPoint(x: 300, y: 300)])
        let rejected = surface.view.phase == .selecting(.lasso) && surface.view.doc.state.crop == nil && unchanged(mark)
        E2E.drag([CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 200, y: 300)])
        let finished = await E2E.until { !E2E.coord.busy }
        if let clip = E2E.checkClipboard(name, since: mark, w: E2E.px(200), h: E2E.px(200)) {
            let mask = clip.png.at(E2E.px(100), E2E.px(60)).a == 1 && clip.png.at(E2E.px(10), E2E.px(180)).a == 0
            E2E.record(name, rejected && finished && clip.ok && mask,
                       clip.info.merging(["invalidLassoRejected": rejected, "lassoMask": mask]) { $1 })
        }
    }
}
#endif
