#if SHAREX_E2E
import AppKit
import ShareXCore

@MainActor
enum E2EStyleFeedback {
    static func run() async {
        let original = E2E.app.settings.value
        defer { E2E.setOpts { $0 = original } }
        E2E.setOpts { $0.options.borderWidth = 0; $0.options.shadow = false; $0.saveToFile = true; $0.saveFolder = E2E.saved.path }
        await defaultsAndControls()
        await nativeGesture()
    }

    private static func slider(_ toolbar: ToolbarView, _ name: String) -> NSSlider? {
        E2EEditing.views(toolbar.e2eStyleContents).compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == name }
    }

    private static func preview(_ toolbar: ToolbarView) -> E2E.Bitmap? {
        let view = toolbar.e2ePreview
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: image)
        return image.cgImage.map(E2E.bitmap)
    }

    private static func openStyle(_ toolbar: ToolbarView) async -> Bool {
        guard E2E.postClick(toolbar.e2eStyle) else { return false }
        return await E2E.until { toolbar.e2ePopoverShown && toolbar.e2eStyleContents.window?.isVisible == true }
    }

    private static func postGesture(_ control: NSSlider, fractions: [CGFloat]) -> Bool {
        guard let window = control.window, let cell = control.cell as? NSSliderCell else { return false }
        let knob = cell.knobRect(flipped: control.isFlipped)
        let start = CGPoint(x: knob.midX, y: knob.midY)
        let points = fractions.map { CGPoint(x: knob.width / 2 + $0 * (control.bounds.width - knob.width), y: start.y) }
        let events: [(NSEvent.EventType, CGPoint)] = [(.leftMouseDown, start)]
            + points.map { (.leftMouseDragged, $0) } + [(.leftMouseUp, points.last ?? start)]
        for (index, item) in events.enumerated() {
            guard let event = NSEvent.mouseEvent(with: item.0, location: control.convert(item.1, to: nil), modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.02,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: index,
                                               clickCount: 1, pressure: item.0 == .leftMouseUp ? 0 : 1) else { return false }
            NSApp.postEvent(event, atStart: false)
        }
        return true
    }

    private static func defaultsAndControls() async {
        guard let s = await E2EEditing.open("style-feedback-open-defaults") else { return }
        let toolbar = s.view.e2eToolbar
        s.view.setTool(.shape(.rectangle))
        guard await openStyle(toolbar), let before = preview(toolbar) else {
            E2E.record("style-feedback-default-preview", false); s.view.cancel(); return
        }
        let peer = EditorView(frame: s.view.bounds, session: s.view.session, viewport: s.view.viewport,
                              image: s.view.renderer.source.tiles[0].image, showMagnifier: false)
        let applied = E2EEditing.color(.blue, in: s) && E2EEditing.button("Fill", in: s)
            && E2EEditing.slider("Opacity", value: 0.4, in: s)
        let swatches = E2EEditing.views(toolbar.e2eStyleContents).compactMap { $0 as? ColorSwatch }
        let peerSwatches = E2EEditing.views(peer.e2eToolbar.e2eStyleContents).compactMap { $0 as? ColorSwatch }
        let values = E2EEditing.views(toolbar.e2eStyleContents).compactMap { $0 as? NSTextField }
        let previewChanged = preview(toolbar).map { before.px != $0.px } ?? false
        E2E.record("style-feedback-default-preview", applied && s.view.doc.annotations.isEmpty && !s.view.doc.history.canUndo
                   && previewChanged && swatches.filter { $0.state == .on }.map(\.color) == [.blue]
                   && peerSwatches.filter { $0.state == .on }.map(\.color) == [.blue]
                   && values.contains { $0.stringValue == "40%" },
                   ["previewPixelsChanged": previewChanged, "sharedSessionViews": 2])
        E2E.snapshotNativeView(toolbar.e2eStyleContents, name: "style-feedback")
        let snapshotSize = (try? Data(contentsOf: E2E.out.appendingPathComponent("style-feedback.png")))?.count ?? 0
        E2E.record("style-feedback-snapshot-size", snapshotSize > 0 && snapshotSize <= 250 * 1024, ["bytes": snapshotSize])
        E2E.record("style-feedback-save-destination", toolbar.e2eOutput.contains(E2E.saved.path)
                   && toolbar.e2eDone.toolTip == "Copy and save screenshot (Return)")
        toolbar.closePopover()
        E2E.drag(CGPoint(x: 150, y: 150), CGPoint(x: 300, y: 250))
        E2E.record("style-feedback-new-mark-default", s.view.doc.selected?.style.color == .blue
                   && s.view.doc.selected?.style.opacity == 0.4 && s.view.doc.selected?.style.filled == true)
        s.view.undo()

        var controls = true
        for (kind, hasWidth, hasOpacity, hasStrength, hasFill) in [
            (ShapeKind.rectangle, true, true, false, true), (.text, true, true, false, true),
            (.highlighter, false, true, false, false), (.blur, false, false, true, false),
            (.pixelate, false, false, true, false), (.spotlight, false, false, true, false),
            (.smartErase, false, false, false, false)
        ] {
            s.view.setTool(.shape(kind))
            let fill = E2EEditing.views(toolbar.e2eStyleContents).compactMap { $0 as? NSButton }.first { $0.title == "Fill" }
            controls = slider(toolbar, "Width / size")?.isEnabled == hasWidth
                && slider(toolbar, "Opacity")?.isEnabled == hasOpacity
                && slider(toolbar, "Effect strength")?.isEnabled == hasStrength
                && fill?.isEnabled == hasFill && controls
        }
        E2E.record("style-feedback-tool-controls", controls && !toolbar.e2eStyle.isEnabled && !toolbar.e2ePopoverShown)
        s.view.setTool(.shape(.rectangle))
        let reset = E2EEditing.button("Reset tool style", in: s)
        E2E.record("style-feedback-reset-default", reset && s.view.doc.style(for: .rectangle) == .defaults(for: .rectangle)
                   && !s.view.doc.history.canUndo)
        s.view.setTool(.shape(.text)); E2E.click(CGPoint(x: 220, y: 200))
        let pending = s.view.session.editingTextID != nil
        let textStyleOpened = await openStyle(toolbar)
        let textChanged = E2EEditing.slider("Width / size", value: 36, in: s)
        E2E.record("style-feedback-empty-text-default", pending && textStyleOpened && textChanged
                   && s.view.doc.annotations.isEmpty && !s.view.doc.history.canUndo
                   && s.view.doc.style(for: .text).fontSize == 36)
        s.view.cancel(); _ = await E2E.until { !E2E.coord.busy }

        E2E.setOpts { $0.saveToFile = false }
        if let clipboard = await E2EEditing.open("style-feedback-open-clipboard-only") {
            E2E.record("style-feedback-clipboard-only", clipboard.view.e2eToolbar.e2eOutput.contains("PNG saving is off")
                       && clipboard.view.e2eToolbar.e2eDone.toolTip == "Copy screenshot (Return)")
            clipboard.view.cancel(); _ = await E2E.until { !E2E.coord.busy }
        }
        E2E.setOpts { $0.saveToFile = true }
    }

    private static func nativeGesture() async {
        guard let s = await E2EEditing.open("style-feedback-open-native-gesture") else { return }
        s.view.setTool(.shape(.rectangle))
        E2E.drag(CGPoint(x: 150, y: 150), CGPoint(x: 300, y: 250))
        let prepared = E2EEditing.color(.blue, in: s) && E2EEditing.button("Fill", in: s)
        let toolbar = s.view.e2eToolbar
        guard prepared, await openStyle(toolbar), let opacity = slider(toolbar, "Opacity") as? TrackingSlider,
              let window = opacity.window, let beforePixels = E2EEditing.image(s),
              let beforeLive = E2E.snapshotImageLayers(s.view, scale: E2E.scale) else {
            E2E.record("style-feedback-native-gesture", false); s.view.cancel(); return
        }
        let before = s.view.doc.state, count = s.view.doc.history.undoStates.count
        var intermediate = false, retainedFocus = false
        let focused = window.makeFirstResponder(opacity)
        toolbar.e2eStyleChanged = { control in
            guard control === opacity, control.doubleValue > 0.4, control.doubleValue < 0.9,
                  s.view.doc.isStyleGestureActive, !intermediate,
                  let exported = E2EEditing.image(s), let live = E2E.snapshotImageLayers(s.view, scale: E2E.scale) else { return }
            let inner = CGRect(x: E2E.px(60), y: E2E.px(60), width: E2E.px(130), height: E2E.px(80))
            let liveInner = inner.offsetBy(dx: CGFloat(E2E.px(E2E.C.minX)), dy: CGFloat(E2E.px(E2E.C.minY)))
            intermediate = E2E.diffFrac(exported, beforePixels, inner) > 0.9
                && E2E.diffFrac(live, beforeLive, liveInner) > 0.9 && s.view.doc.history.undoStates.count == count
            retainedFocus = window.firstResponder === opacity
        }
        let posted = postGesture(opacity, fractions: [0.6, 0.25])
        let settled = await E2E.until { !s.view.doc.isStyleGestureActive && s.view.doc.history.undoStates.count == count + 1 }
        toolbar.e2eStyleChanged = nil
        let after = s.view.doc.state
        toolbar.closePopover()
        let dismissed = await E2E.until { !toolbar.e2ePopoverShown && s.window.firstResponder === s.view }
        s.view.undo(); let undone = s.view.doc.state == before
        s.view.redo(); let redone = s.view.doc.state == after
        E2E.record("style-feedback-native-gesture", focused && posted && settled && intermediate && retainedFocus && undone && redone && dismissed,
                   ["nativeWindowEvents": true, "intermediatePixelsChanged": intermediate, "sliderKeptFocus": retainedFocus,
                    "oneUndoRestoredStyle": undone, "redoRestoredStyle": redone])

        guard await openStyle(toolbar) else { E2E.record("style-feedback-reopen", false); s.view.cancel(); return }
        let noOpCount = s.view.doc.history.undoStates.count
        let gestureCount = opacity.e2eCompletedGestures
        let noOpPosted = postGesture(opacity, fractions: [])
        let noOpCompleted = await E2E.until { opacity.e2eCompletedGestures == gestureCount + 1 }
        E2E.record("style-feedback-native-noop", noOpPosted && noOpCompleted && !s.view.doc.isStyleGestureActive
                   && s.view.doc.history.undoStates.count == noOpCount)

        guard let keyWindow = opacity.window else { E2E.record("style-feedback-native-keyboard", false); s.view.cancel(); return }
        var keyboard = keyWindow.makeFirstResponder(opacity)
        let firstValue = opacity.doubleValue
        for _ in 0..<2 {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: keyWindow.windowNumber,
                                                 context: nil, characters: "\u{f703}", charactersIgnoringModifiers: "\u{f703}",
                                                 isARepeat: false, keyCode: 124) else { keyboard = false; continue }
                keyWindow.sendEvent(event)
            }
        }
        let lastValue = opacity.doubleValue
        keyboard = keyboard && lastValue > firstValue && s.view.doc.history.undoStates.count == noOpCount + 2
        toolbar.closePopover()
        s.view.undo(); let middleValue = s.view.doc.selected?.style.opacity ?? 0
        s.view.undo()
        E2E.record("style-feedback-native-keyboard", keyboard && middleValue > firstValue && middleValue < lastValue
                   && s.view.doc.selected?.style.opacity == firstValue)
        let expected = E2EEditing.image(s)
        await E2EEditing.finish("style-feedback-export", s, condition: expected != nil) { $0.px == expected?.px }
    }
}
#endif
