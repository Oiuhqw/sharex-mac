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
        let shown = await E2E.until { toolbar.e2ePopoverPresented && toolbar.e2eStyleContents.window?.isVisible == true }
        toolbar.e2eStyleContents.layoutSubtreeIfNeeded()
        toolbar.e2eStyleContents.displayIfNeeded()
        return shown
    }

    private static func postGesture(_ control: NSSlider, fractions: [CGFloat]) -> StyleHIDGesture? {
        guard CGPreflightPostEventAccess(), let window = control.window, window.isVisible, control.isEnabled,
              let cell = control.cell as? NSSliderCell, let primary = NSScreen.screens.first,
              let source = CGEventSource(stateID: .combinedSessionState) else { return nil }
        control.display()
        let knob = cell.knobRect(flipped: control.isFlipped)
        guard !knob.isEmpty, control.bounds.intersects(knob) else { return nil }
        let start = CGPoint(x: knob.midX, y: knob.midY)
        let points = fractions.map { CGPoint(x: knob.width / 2 + $0 * (control.bounds.width - knob.width), y: start.y) }
        guard let content = window.contentView, content.hitTest(control.convert(start, to: content.superview)) === control,
              points.allSatisfy({ control.bounds.contains($0) }) else { return nil }
        let positions: [(CGEventType, CGPoint)] = [(.mouseMoved, start), (.leftMouseDown, start)]
            + points.map { (.leftMouseDragged, $0) } + [(.leftMouseUp, points.last ?? start)]
        var events: [CGEvent] = []
        for item in positions {
            let screen = window.convertPoint(toScreen: control.convert(item.1, to: nil))
            guard let event = CGEvent(mouseEventSource: source, mouseType: item.0,
                                      mouseCursorPosition: CGPoint(x: screen.x, y: primary.frame.maxY - screen.y),
                                      mouseButton: .left) else { return nil }
            event.flags = []
            event.setIntegerValueField(.mouseEventClickState, value: item.0 == .mouseMoved ? 0 : 1)
            event.setIntegerValueField(.mouseEventNumber, value: item.0 == .mouseMoved ? 0 : 1)
            event.setDoubleValueField(.mouseEventPressure, value: item.0 == .leftMouseDown || item.0 == .leftMouseDragged ? 1 : 0)
            events.append(event)
        }
        let gesture = StyleHIDGesture(events)
        gesture.start()
        return gesture
    }

    private static func inputState(_ control: NSSlider, event: NSEvent?) -> [String: Any] {
        guard let window = control.window else { return ["error": "slider has no window"] }
        let cursor = control.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let location = event.map { control.convert($0.locationInWindow, from: nil) } ?? .zero
        let knob = (control.cell as? NSSliderCell)?.knobRect(flipped: control.isFlipped) ?? .zero
        let start = CGPoint(x: knob.midX, y: knob.midY)
        let content = window.contentView
        let hit = content?.hitTest(control.convert(start, to: content?.superview))
        return ["eventType": event?.type.rawValue ?? 0, "eventWindow": event?.windowNumber ?? 0,
                "buttonEventNumber": event?.eventNumber ?? 0,
                "sliderWindow": window.windowNumber, "eventLocation": [location.x, location.y],
                "knob": NSStringFromRect(knob), "bounds": NSStringFromRect(control.bounds),
                "knobHitView": hit.map { String(describing: type(of: $0)) } ?? "none",
                "cursor": [cursor.x, cursor.y], "pressedMouseButtons": NSEvent.pressedMouseButtons,
                "sessionLeftButtonDown": CGEventSource.buttonState(.combinedSessionState, button: .left),
                "focused": window.firstResponder === control, "keyWindow": window.isKeyWindow]
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
        if let window = toolbar.e2eStyleContents.window {
            await E2E.snapshotNativeWindow(window, name: "style-feedback-window")
        } else { E2E.record("style-feedback", false, ["error": "popover has no window"]) }
        E2E.snapshotNativeView(toolbar.e2eStyleContents, name: "style-feedback")
        let snapshotSize = (try? Data(contentsOf: E2E.out.appendingPathComponent("style-feedback.png")))?.count ?? 0
        E2E.record("style-feedback-snapshot-size", snapshotSize > 0 && snapshotSize <= 250 * 1024, ["bytes": snapshotSize])
        E2E.record("style-feedback-save-destination", toolbar.e2eOutput.contains(E2E.saved.path)
                   && toolbar.e2eDone.toolTip == "Copy and save screenshot (Return)")
        toolbar.closePopover()
        let closed = await E2E.until { !toolbar.e2ePopoverShown }
        E2E.drag(CGPoint(x: 150, y: 150), CGPoint(x: 300, y: 250))
        E2E.record("style-feedback-new-mark-default", s.view.doc.selected?.style.color == .blue
                   && s.view.doc.selected?.style.opacity == 0.4 && s.view.doc.selected?.style.filled == true)
        s.view.undo()

        var controls = true, controlStates: [String: [Bool]] = [:]
        for (kind, hasWidth, hasOpacity, hasStrength, hasFill) in [
            (ShapeKind.rectangle, true, true, false, true), (.text, true, true, false, true),
            (.highlighter, false, true, false, false), (.blur, false, false, true, false),
            (.pixelate, false, false, true, false), (.spotlight, false, false, true, false),
            (.smartErase, false, false, false, false)
        ] {
            s.view.setTool(.shape(kind))
            let fill = E2EEditing.views(toolbar.e2eStyleContents).compactMap { $0 as? NSButton }.first { $0.title == "Fill" }
            let matches = slider(toolbar, "Width / size")?.isEnabled == hasWidth
                && slider(toolbar, "Opacity")?.isEnabled == hasOpacity
                && slider(toolbar, "Effect strength")?.isEnabled == hasStrength
                && fill?.isEnabled == hasFill
            controlStates[kind.rawValue] = [slider(toolbar, "Width / size")?.isEnabled ?? false,
                                           slider(toolbar, "Opacity")?.isEnabled ?? false,
                                           slider(toolbar, "Effect strength")?.isEnabled ?? false, fill?.isEnabled ?? false]
            controls = controls && matches
        }
        E2E.record("style-feedback-tool-controls", controls && closed && !toolbar.e2eStyle.isEnabled && !toolbar.e2ePopoverShown,
                   ["controlsByTool": controlStates, "popoverClosed": closed, "styleEnabled": toolbar.e2eStyle.isEnabled])
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
        var values: [Double] = [], historyCounts: [Int] = []
        var trackingStarts: [[String: Any]] = [], actionInputs: [[String: Any]] = []
        var downDelivered = false
        let gestureCount = opacity.e2eCompletedGestures
        let focused = window.makeFirstResponder(opacity)
        opacity.e2eTrackingBegan = { event in
            trackingStarts.append(inputState(opacity, event: event))
            let point = opacity.convert(event.locationInWindow, from: nil)
            let cursor = opacity.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            downDelivered = event.type == .leftMouseDown && event.windowNumber == window.windowNumber
                && (opacity.cell as? NSSliderCell)?.knobRect(flipped: opacity.isFlipped).contains(point) == true
                && hypot(cursor.x - point.x, cursor.y - point.y) < 3 && NSEvent.pressedMouseButtons & 1 != 0
        }
        toolbar.e2eStyleChanged = { control in
            guard control === opacity else { return }
            values.append(control.doubleValue); historyCounts.append(s.view.doc.history.undoStates.count)
            actionInputs.append(inputState(control, event: NSApp.currentEvent))
            guard control.doubleValue > 0.4, control.doubleValue < 0.9,
                  s.view.doc.isStyleGestureActive, !intermediate,
                  let exported = E2EEditing.image(s), let live = E2E.snapshotImageLayers(s.view, scale: E2E.scale) else { return }
            let inner = CGRect(x: E2E.px(60), y: E2E.px(60), width: E2E.px(130), height: E2E.px(80))
            let liveInner = inner.offsetBy(dx: CGFloat(E2E.px(E2E.C.minX)), dy: CGFloat(E2E.px(E2E.C.minY)))
            intermediate = E2E.diffFrac(exported, beforePixels, inner) > 0.9
                && E2E.diffFrac(live, beforeLive, liveInner) > 0.9 && s.view.doc.history.undoStates.count == count
            retainedFocus = window.firstResponder === opacity
        }
        let gesture = postGesture(opacity, fractions: [0.6, 0.25])
        let completed = await E2E.until { gesture?.isFinished == true && opacity.e2eCompletedGestures == gestureCount + 1 }
        let settled = await E2E.until { !s.view.doc.isStyleGestureActive && s.view.doc.history.undoStates.count == count + 1 }
        toolbar.e2eStyleChanged = nil
        opacity.e2eTrackingBegan = nil
        let released = NSEvent.pressedMouseButtons & 1 == 0
        E2E.record("style-feedback-native-delivery", completed && downDelivered && released && trackingStarts.count == 1,
                   ["eventPostingPermitted": CGPreflightPostEventAccess(), "completed": completed,
                    "sliderState": inputState(opacity, event: nil),
                    "downDeliveredAtKnob": downDelivered, "released": released,
                    "postedEvents": gesture?.postedEvents ?? [], "trackingStarts": trackingStarts, "actionInputs": actionInputs])
        let after = s.view.doc.state
        let finalCount = s.view.doc.history.undoStates.count
        toolbar.closePopover()
        let dismissed = await E2E.until { !toolbar.e2ePopoverShown && s.window.firstResponder === s.view }
        s.view.undo(); let undone = s.view.doc.state == before
        s.view.redo(); let redone = s.view.doc.state == after
        E2E.record("style-feedback-native-gesture", focused && completed && downDelivered && settled && intermediate && retainedFocus && undone && redone && dismissed,
                   ["nativeHIDEvents": true, "intermediatePixelsChanged": intermediate, "sliderKeptFocus": retainedFocus,
                    "oneUndoRestoredStyle": undone, "redoRestoredStyle": redone, "focused": focused,
                    "posted": gesture != nil, "settled": settled, "dismissed": dismissed,
                    "actionValues": values, "historyCounts": historyCounts, "historyBefore": count, "historyAfter": finalCount])

        guard await openStyle(toolbar) else { E2E.record("style-feedback-reopen", false); s.view.cancel(); return }
        let noOpCount = s.view.doc.history.undoStates.count
        let noOpState = s.view.doc.state, noOpGestureCount = opacity.e2eCompletedGestures
        let noOp = postGesture(opacity, fractions: [])
        let noOpCompleted = await E2E.until { noOp?.isFinished == true && opacity.e2eCompletedGestures == noOpGestureCount + 1 }
        E2E.record("style-feedback-native-noop", noOpCompleted && !s.view.doc.isStyleGestureActive
                   && s.view.doc.history.undoStates.count == noOpCount && s.view.doc.state == noOpState,
                   ["postedEvents": noOp?.postedEvents ?? [], "completed": noOpCompleted])

        guard let keyWindow = opacity.window else { E2E.record("style-feedback-native-keyboard", false); s.view.cancel(); return }
        keyWindow.makeKey()
        let keyboardFocused = keyWindow.makeFirstResponder(opacity) && keyWindow.isKeyWindow
        var keyboard = keyboardFocused
        let firstValue = opacity.doubleValue
        for index in 1...2 {
            await E2EKeyboard.post(124)
            let changed = await E2E.until { s.view.doc.history.undoStates.count == noOpCount + index }
            keyboard = keyboard && changed && keyWindow.firstResponder === opacity
        }
        let lastValue = opacity.doubleValue
        let keyHistoryCount = s.view.doc.history.undoStates.count
        keyboard = keyboard && lastValue > firstValue && keyHistoryCount == noOpCount + 2
        toolbar.closePopover()
        s.view.undo(); let middleValue = s.view.doc.selected?.style.opacity ?? 0
        s.view.undo()
        E2E.record("style-feedback-native-keyboard", keyboard && middleValue > firstValue && middleValue < lastValue
                   && s.view.doc.selected?.style.opacity == firstValue,
                   ["nativeHIDEvents": true, "focused": keyboardFocused, "firstValue": firstValue, "lastValue": lastValue, "middleValue": middleValue,
                    "historyBefore": noOpCount, "historyAfter": keyHistoryCount])
        let expected = E2EEditing.image(s)
        await E2EEditing.finish("style-feedback-export", s, condition: expected != nil) { $0.px == expected?.px }
    }
}

@MainActor
private final class StyleHIDGesture: NSObject {
    private var events: [CGEvent]
    private(set) var postedEvents: [[String: Any]] = []
    var isFinished: Bool { events.isEmpty }

    init(_ events: [CGEvent]) { self.events = events; super.init() }

    func start() {
        let timer = Timer(timeInterval: 0.15, target: self, selector: #selector(postNext(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        postNext(timer)
    }

    @objc private func postNext(_ timer: Timer) {
        let event = events.removeFirst()
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        postedEvents.append(["type": event.type.rawValue, "screen": [event.location.x, event.location.y],
                             "buttonEventNumber": event.getIntegerValueField(.mouseEventNumber),
                             "leftButtonDownBeforePost": CGEventSource.buttonState(.combinedSessionState, button: .left)])
        event.post(tap: .cghidEventTap)
        if events.isEmpty { timer.invalidate() }
    }
}
#endif
