#if SHAREX_E2E
import AppKit
import ShareXCore

@MainActor
enum E2ECapturePolish {
    static func run() async {
        await outputSnapshot()
        await windowOutputSnapshot()
        await canvasToolbarPadding()
        let sound = NSSound(data: CaptureSound.waveData)
        try? CaptureSound.waveData.write(to: E2E.out.appendingPathComponent("capture-click.wav"))
        E2E.record("capture-sound-decodes-short-shutter", sound != nil && abs((sound?.duration ?? 0) - 0.09) < 0.002,
                   ["duration": sound?.duration ?? 0, "bytes": CaptureSound.waveData.count])
        let defaults = AppSettings.decode(nil)
        let legacy = AppSettings.decode(Data("{}".utf8))
        let optedOut = AppSettings.decode(Data("{\"saveToFile\":false}".utf8))
        E2E.record("capture-saving-default-and-opt-out", defaults.saveToFile && legacy.saveToFile && !optedOut.saveToFile)

        guard let source = E2ELoupe.fixture(), let context = Imaging.context(width: 220, height: 200, flipped: true) else {
            E2E.record("capture-round-loupe-fixture", false); return
        }
        let chrome = ChromeView(frame: CGRect(x: 0, y: 0, width: 220, height: 200))
        chrome.setMagnifierSource(source)
        var state = ChromeView.State()
        state.magnifier = (CGPoint(x: 20, y: 20), 2)
        chrome.apply(state)
        chrome.layer?.render(in: context)
        guard let image = context.makeImage() else { E2E.record("capture-round-loupe", false); return }
        let bitmap = E2E.bitmap(image), frame = chrome.e2eLoupe.frame
        let corners = [(frame.minX + 2, frame.minY + 2), (frame.maxX - 3, frame.minY + 2),
                       (frame.minX + 2, frame.maxY - 3), (frame.maxX - 3, frame.maxY - 3)]
        let clearCorners = corners.allSatisfy { bitmap.at(Int($0.0), Int($0.1)).a < 0.01 }
        let center = bitmap.at(Int(frame.midX), Int(frame.midY))
        E2E.record("capture-round-loupe-rendered", clearCorners && center.a > 0.99,
                   ["clearCorners": clearCorners, "centerAlpha": center.a])
        E2EOrientation.writePNG(image, "round-loupe.png")
        chrome.releaseResources()
    }

    private static func outputSnapshot() async {
        let original = E2E.app.settings.value
        defer { E2E.setOpts { $0 = original } }
        E2E.setOpts {
            $0.saveToFile = true; $0.saveFolder = E2E.saved.path; $0.playSound = false
            $0.options.borderWidth = 0; $0.options.shadow = false
        }
        guard let session = await E2EEditing.open("capture-output-snapshot") else { return }
        let shown = session.view.session.outputSummary.contains(E2E.saved.path)
            && session.view.session.outputAction == "Copy and save"
        E2E.setOpts { $0.saveToFile = false; $0.saveFolder = "/invalid/changed-during-capture" }
        await E2EEditing.finish("capture-output-snapshot", session, condition: shown,
                                info: ["settingsChangedWhileOpen": true]) { $0.px == session.original.px }
    }

    private static func windowOutputSnapshot() async {
        let original = E2E.app.settings.value
        defer { E2E.setOpts { $0 = original } }
        guard let target = E2E.patternWindow() else {
            E2E.record("capture-window-output-snapshot", false, ["error": "pattern window missing"]); return
        }
        let rect = Geometry.cocoaToDisplayTopLeft(target.frame, screenFrame: E2E.screen.frame)
        for edit in [false, true] {
            let name = "capture-window-output-snapshot-\(edit ? "editor" : "direct")"
            E2E.setOpts {
                $0.saveToFile = true; $0.saveFolder = E2E.saved.path; $0.playSound = false
                $0.options.borderWidth = 0; $0.options.shadow = false
                $0.options.openEditor = edit; $0.options.delaySeconds = 0
                $0.toolStyles = [.rectangle: .defaults(for: .rectangle)]
            }
            let mark = E2E.markClipboard()
            E2E.coord.capture(.windowPicker)
            guard await E2E.until({ E2E.surface() != nil }), let picker = E2E.surface() else {
                E2E.record(name, false, ["error": "window picker missing"]); return
            }
            var shown = picker.view.session.outputSummary.contains(E2E.saved.path)
            picker.view.setTool(.shape(.rectangle))
            picker.view.changeStyle { $0.color = .blue }
            picker.view.session.chooseSelection(.pickWindow)
            E2E.setOpts { $0.saveToFile = false; $0.saveFolder = "/invalid/changed-during-capture"; $0.options.openEditor = !edit }
            E2E.click(CGPoint(x: rect.midX, y: rect.midY))
            if edit {
                let opened = await E2E.until(6000, { E2E.surface()?.view.phase == .editing })
                shown = shown && opened && E2E.surface()?.view.session.outputSummary.contains(E2E.saved.path) == true
                    && E2E.surface()?.view.doc.style(for: .rectangle).color == .blue
                E2E.surface()?.view.finish()
            }
            let finished = await E2E.until(6000, { !E2E.coord.busy })
            if !finished { E2E.surface()?.view.cancel() }
            if let clip = E2E.checkClipboard(name, since: mark,
                                             w: Int((target.frame.width * E2E.scale).rounded()),
                                             h: Int((target.frame.height * E2E.scale).rounded())) {
                E2E.record(name, shown && finished && clip.ok && E2E.app.settings.value.toolStyles[.rectangle]?.color == .blue, clip.info)
            }
        }
    }

    private static func canvasToolbarPadding() async {
        for (name, width, height, scale) in [("compact", 640, 300, CGFloat(1)), ("wide", 960, 300, CGFloat(1)),
                                             ("retina", 1280, 600, CGFloat(2)), ("tall", 640, 1600, CGFloat(1))] {
            let name = "capture-canvas-\(name)"
            guard let context = Imaging.context(width: width, height: height, flipped: true) else {
                E2E.record(name, false, ["error": "canvas fixture allocation failed"]); continue
            }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(NSColor.green.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: 8))
            context.setFillColor(NSColor.blue.cgColor)
            context.fill(CGRect(x: 0, y: height - 8, width: width, height: 8))
            guard let image = context.makeImage() else { E2E.record(name, false); continue }
            var result: EditorResult?
            var outcomes = 0
            var settings = AppSettings(); settings.options.showMagnifier = false
            let controller = OverlayController(canvas: image, scale: scale, screen: E2E.screen, title: name,
                                               settings: settings, onStyles: { _ in }) {
                outcomes += 1
                if case .finished(let finished) = $0 { result = finished }
            }
            controller.show()
            guard let surface = controller.e2eSurfaces.first, let crop = surface.view.doc.state.crop else {
                E2E.record(name, false, ["error": "canvas editor missing"]); continue
            }
            let view = surface.view, toolbar = view.e2eToolbar, viewScale = view.renderer.scale
            let original = E2E.bitmap(image)
            let unchanged = Export.flatten(renderer: view.renderer, doc: view.doc, crop: crop, lasso: nil).map(E2E.bitmap)
            let room = CGSize(width: E2E.screen.visibleFrame.width - 40, height: E2E.screen.visibleFrame.height - 80)
            E2E.record("\(name)-toolbar-clear", !toolbar.frame.intersects(crop) && toolbar.frame.maxY < crop.minY
                       && view.bounds.contains(crop) && unchanged?.px == original.px
                       && view.bounds.width <= room.width && view.bounds.height <= room.height,
                       ["toolbar": NSStringFromRect(toolbar.frame), "crop": NSStringFromRect(crop),
                        "canvas": NSStringFromSize(view.bounds.size), "room": NSStringFromSize(room), "viewScale": viewScale,
                        "originalPixelsPreserved": unchanged?.px == original.px])

            view.setTool(.select)
            let chosen = toolbar.e2eButton("Rectangle").map { E2E.postClick($0) } ?? false
            let ready = await E2E.until { view.tool == .shape(.rectangle) }
            view.changeStyle { $0.color = .red; $0.filled = true; $0.opacity = 1; $0.width = 2 }
            let mark = CGRect(x: crop.minX + 120 / viewScale, y: crop.minY + 12 / viewScale,
                              width: 80 / viewScale, height: 32 / viewScale)
            E2E.mouse(.leftMouseDown, mark.origin, in: surface)
            E2E.mouse(.leftMouseDragged, CGPoint(x: mark.maxX, y: mark.maxY), in: surface)
            E2E.mouse(.leftMouseUp, CGPoint(x: mark.maxX, y: mark.maxY), in: surface)
            let annotated = chosen && ready && view.doc.annotations.count == 1
            view.setTool(.select)
            let background = CGPoint(x: crop.midX, y: crop.midY)
            E2E.mouse(.leftMouseDown, background, in: surface)
            E2E.mouse(.leftMouseUp, background, in: surface)
            if let native = await E2E.snapshotNativeWindow(surface.window, name: "\(name)-native-window") {
                func pixel(_ point: CGPoint) -> (r: Double, g: Double, b: Double, a: Double) {
                    let point = view.convert(point, to: nil), backing = surface.window.backingScaleFactor
                    return native.at(Int(point.x * backing), Int((surface.window.frame.height - point.y) * backing))
                }
                let edge = pixel(CGPoint(x: crop.minX + 30 / viewScale, y: crop.minY + 4 / viewScale))
                let red = pixel(CGPoint(x: mark.midX, y: mark.midY))
                E2E.record("\(name)-top-edge-visible", annotated && edge.g > 0.9 && edge.r < 0.1 && E2E.isRed(red),
                           ["nativeWindowEvents": true, "topGreen": edge.g, "markRed": red.r, "markGreen": red.g])
            }
            let posted = E2E.postClick(toolbar.e2eDone)
            let finished = await E2E.until { outcomes > 0 }
            if let result {
                let exported = E2E.bitmap(result.image)
                var unchangedOutsideMark = exported.w == width && exported.h == height
                if unchangedOutsideMark {
                    for y in 0..<height {
                        for x in 0..<width where x < 112 || x >= 208 || y < 8 || y >= 48 {
                            let index = (y * width + x) * 4
                            if exported.px[index..<(index + 4)] != original.px[index..<(index + 4)] { unchangedOutsideMark = false }
                        }
                    }
                }
                let red = exported.at(160, 28)
                E2E.record("\(name)-native-export", annotated && posted && finished && outcomes == 1 && result.scale == scale
                           && unchangedOutsideMark && E2E.isRed(red) && !surface.window.isVisible,
                           ["width": exported.w, "height": exported.h, "outputScale": result.scale,
                            "originalPixelsOutsideMark": unchangedOutsideMark, "annotations": view.doc.annotations.count])
                E2EOrientation.writePNG(result.image, "\(name)-export.png")
            } else { E2E.record("\(name)-native-export", false, ["error": "Done did not finish canvas editing"]) }
            controller.session?.cancel()
        }
    }
}
#endif
