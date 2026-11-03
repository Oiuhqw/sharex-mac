#if SHAREX_E2E
import AppKit
import ShareXCore

/// Native editor regressions. Mouse drags go through NSWindow, keys go through its responder chain,
/// and toolbar actions are sent by the actual NSControls. Final images are read from the pasteboard.
/// These are local AppKit events/control actions, not a claim of physical HID or mouse testing.
@MainActor
enum E2EEditing {
    struct Session {
        let mark: (change: Int, files: [String])
        let window: NSWindow
        let view: EditorView
        let original: E2E.Bitmap
    }

    static func views(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { views($0) }
    }

    @discardableResult
    static func tool(_ tip: String, in s: Session) -> Bool {
        guard let control = views(s.view).compactMap({ $0 as? NSSegmentedControl }).first,
              let index = (0..<control.segmentCount).first(where: { control.toolTip(forSegment: $0) == tip }) else { return false }
        control.selectedSegment = index
        return control.sendAction(control.action, to: control.target)
    }

    @discardableResult
    static func button(_ tip: String, in s: Session) -> Bool {
        guard let control = views(s.view).compactMap({ $0 as? NSButton }).first(where: { $0.toolTip == tip || $0.title == tip }),
              control.isEnabled else { return false }
        control.performClick(nil)
        return true
    }

    @discardableResult
    static func color(_ color: RGBA, in s: Session) -> Bool {
        guard let index = RGBA.palette.firstIndex(of: color),
              let control = views(s.view).compactMap({ $0 as? NSButton }).first(where: { !$0.isBordered && $0.tag == index }) else { return false }
        control.performClick(nil)
        return true
    }

    @discardableResult
    static func slider(_ tip: String, value: Double, in s: Session) -> Bool {
        guard let control = views(s.view).compactMap({ $0 as? NSSlider }).first(where: { $0.toolTip == tip }),
              control.isEnabled else { return false }
        control.doubleValue = value
        return control.sendAction(control.action, to: control.target)
    }

    static func key(_ code: UInt16, _ chars: String, in s: Session, flags: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: s.window.windowNumber,
                                             context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                             isARepeat: false, keyCode: code) else { continue }
            s.window.sendEvent(event)
        }
    }

    static func image(_ s: Session) -> E2E.Bitmap? {
        Export.flatten(renderer: s.view.renderer, doc: s.view.doc, crop: E2E.C, lasso: nil).map(E2E.bitmap)
    }

    static func open(_ name: String, from: CGPoint? = nil, to: CGPoint? = nil) async -> Session? {
        E2E.setOpts { $0.toolStyles = [:]; $0.options.openEditor = true; $0.options.delaySeconds = 0 }
        let mark = E2E.markClipboard()
        E2E.coord.capture(.region)
        guard await E2E.until({ E2E.surface() != nil }), let surface = E2E.surface() else {
            E2E.record(name, false, ["error": "selection overlay did not open"]); return nil
        }
        E2E.drag(from ?? E2E.C.origin, to ?? CGPoint(x: E2E.C.maxX, y: E2E.C.maxY))
        guard surface.view.phase == .editing, surface.view.doc.state.crop == E2E.C,
              let frame = surface.view.renderer.frame.cropping(to: CGRect(x: E2E.C.minX * E2E.scale, y: E2E.C.minY * E2E.scale,
                                                                          width: E2E.C.width * E2E.scale, height: E2E.C.height * E2E.scale)) else {
            E2E.record(name, false, ["error": "drag did not select the expected rectangle"])
            surface.view.cancel(); _ = await E2E.until({ !E2E.coord.busy }); return nil
        }
        return Session(mark: mark, window: surface.window, view: surface.view, original: E2E.bitmap(frame))
    }

    static func finish(_ name: String, _ s: Session, condition: Bool, info: [String: Any] = [:],
                       pixels: (E2E.Bitmap) -> Bool) async {
        key(36, "\r", in: s)
        guard await E2E.until({ !E2E.coord.busy }) else {
            E2E.record(name, false, ["error": "Return through the window responder chain did not finish"])
            s.view.cancel(); _ = await E2E.until({ !E2E.coord.busy }); return
        }
        guard let clip = E2E.checkClipboard(name, since: s.mark, w: E2E.cw, h: E2E.ch) else { return }
        let match = pixels(clip.png)
        E2E.record(name, condition && clip.ok && match,
                   clip.info.merging(info) { $1 }.merging(["pixelAssertion": match, "nativeWindowEvents": true]) { $1 })
    }

    static func run() async {
        let original = E2E.app.settings.value
        defer { E2E.setOpts { $0 = original } }
        E2E.setOpts { $0.options.borderWidth = 0; $0.options.shadow = false; $0.saveToFile = true; $0.saveFolder = E2E.saved.path }
        await dragDirections()
        await resetSelection()
        await toolbarMoveResize()
        await opaqueRedaction()
        await effectErase(.blur, tip: "Blur (B)", keyboard: true)
        await effectErase(.pixelate, tip: "Pixelate (P)", keyboard: false)
        await penErase()
    }

    static func dragDirections() async {
        let a = E2E.C.origin, b = CGPoint(x: E2E.C.maxX, y: E2E.C.maxY)
        let c = CGPoint(x: b.x, y: a.y), d = CGPoint(x: a.x, y: b.y)
        for (index, pair) in [(a, b), (b, a), (c, d), (d, c)].enumerated() {
            let name = "editing-region-drag-direction-\(index + 1)"
            guard let s = await open(name, from: pair.0, to: pair.1) else { continue }
            await finish(name, s, condition: true) { $0.px == s.original.px }
        }
    }

    static func resetSelection() async {
        let name = "editing-rightclick-reset-and-tiny-drag"
        guard let s = await open(name) else { return }
        E2E.mouse(.rightMouseDown, CGPoint(x: 200, y: 200), in: (s.window, s.view))
        let reset = s.view.phase == .selecting(.rectangle) && s.view.doc.state.crop == nil
        E2E.drag(CGPoint(x: 200, y: 200), CGPoint(x: 200.25, y: 200.25))
        let tinyRejected = s.view.phase == .selecting(.rectangle) && s.view.doc.state.crop == nil
        E2E.drag(E2E.C.origin, CGPoint(x: E2E.C.maxX, y: E2E.C.maxY))
        await finish(name, s, condition: reset && tinyRejected && s.view.doc.state.crop == E2E.C,
                     info: ["reset": reset, "tinyDragRejected": tinyRejected]) { $0.px == s.original.px }
    }

    static func toolbarMoveResize() async {
        let name = "editing-toolbar-color-fill-move-resize-undo"
        guard let s = await open(name) else { return }
        var ok = tool("Rectangle (R)", in: s)
        E2E.drag(CGPoint(x: 150, y: 150), CGPoint(x: 250, y: 220))
        ok = button("Fill", in: s) && ok
        ok = color(.blue, in: s) && ok
        ok = slider("Width / size", value: 8, in: s) && ok
        ok = s.view.doc.selected?.style.color == .blue && s.view.doc.selected?.style.filled == true
            && s.view.doc.selected?.style.width == 8 && s.window.firstResponder === s.view && ok
        ok = tool("Select (V)", in: s) && ok
        E2E.drag(CGPoint(x: 200, y: 185), CGPoint(x: 300, y: 235))
        ok = s.view.doc.selected?.rect == CGRect(x: 250, y: 200, width: 100, height: 70) && ok
        E2E.drag(CGPoint(x: 350, y: 270), CGPoint(x: 400, y: 310))
        ok = s.view.doc.selected?.rect == CGRect(x: 250, y: 200, width: 150, height: 110) && ok
        key(124, "\u{f703}", in: s)
        key(125, "\u{f701}", in: s, flags: .shift)
        let moved = CGRect(x: 251, y: 210, width: 150, height: 110)
        ok = s.view.doc.selected?.rect == moved && ok
        ok = button("Undo (⌘Z)", in: s) && ok
        ok = s.view.doc.selected?.rect == CGRect(x: 251, y: 200, width: 150, height: 110) && ok
        ok = button("Redo (⇧⌘Z)", in: s) && ok
        ok = s.view.doc.selected?.rect == moved && ok
        await finish(name, s, condition: ok) { bitmap in
            let inside = bitmap.at(E2E.px(200), E2E.px(150))
            let old = bitmap.at(E2E.px(70), E2E.px(70)), expected = s.original.at(E2E.px(70), E2E.px(70))
            return E2E.isBlue(inside) && abs(old.r - expected.r) + abs(old.g - expected.g) + abs(old.b - expected.b) < 0.02
        }
    }

    static func opaqueRedaction() async {
        let name = "editing-opaque-box-hides-source"
        guard let s = await open(name) else { return }
        var ok = tool("Rectangle (R)", in: s)
        E2E.drag(CGPoint(x: 150, y: 150), CGPoint(x: 300, y: 250))
        ok = button("Fill", in: s) && ok
        ok = color(.black, in: s) && ok
        ok = slider("Opacity", value: 1, in: s) && ok
        await finish(name, s, condition: ok) { bitmap in
            let inner = CGRect(x: E2E.px(60), y: E2E.px(60), width: E2E.px(130), height: E2E.px(80))
            let allBlack = bitmap.frac(inner) { $0.r < 0.01 && $0.g < 0.01 && $0.b < 0.01 && $0.a == 1 } == 1
            let outside = E2E.diffFrac(bitmap, s.original, CGRect(x: 0, y: 0, width: E2E.px(40), height: E2E.px(40)))
            return allBlack && outside == 0
        }
    }

    static func effectErase(_ kind: ShapeKind, tip: String, keyboard: Bool) async {
        let name = "editing-\(kind.rawValue)-erase-undo-redo"
        guard let s = await open(name) else { return }
        var ok = tool(tip, in: s)
        E2E.drag(CGPoint(x: 150, y: 150), CGPoint(x: 300, y: 250))
        let inner = CGRect(x: E2E.px(60), y: E2E.px(60), width: E2E.px(130), height: E2E.px(80))
        let effectVisible = image(s).map { E2E.diffFrac($0, s.original, inner) > 0.15 } ?? false
        if keyboard { key(51, "\u{7f}", in: s) }
        else { E2E.mouse(.rightMouseDown, CGPoint(x: 220, y: 200), in: (s.window, s.view)) }
        let erased = s.view.doc.annotations.isEmpty && image(s)?.px == s.original.px
        ok = button("Undo (⌘Z)", in: s) && ok
        let restored = s.view.doc.annotations.count == 1 && (image(s).map { E2E.diffFrac($0, s.original, inner) > 0.15 } ?? false)
        ok = button("Redo (⇧⌘Z)", in: s) && ok
        await finish(name, s, condition: ok && effectVisible && erased && restored && s.view.doc.annotations.isEmpty,
                     info: ["effectVisible": effectVisible, "erased": erased, "undoRestored": restored]) { $0.px == s.original.px }
    }

    static func penErase() async {
        let name = "editing-pen-draw-and-toolbar-delete"
        guard let s = await open(name) else { return }
        key(3, "f", in: s)
        var ok = s.view.tool == .shape(.pen)
        E2E.drag([CGPoint(x: 150, y: 150), CGPoint(x: 230, y: 190), CGPoint(x: 300, y: 160)])
        ok = s.view.doc.annotations.first?.points.count == 3 && ok
        let drawn = image(s).map { E2E.isRed($0.at(E2E.px(130), E2E.px(90))) } ?? false
        ok = button("Delete selected (⌫)", in: s) && ok
        await finish(name, s, condition: ok && drawn && s.view.doc.annotations.isEmpty,
                     info: ["penPixelsVisible": drawn]) { $0.px == s.original.px }
    }
}
#endif
