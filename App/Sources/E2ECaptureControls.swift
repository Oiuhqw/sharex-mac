#if SHAREX_E2E
import AppKit
import ShareXCore

@MainActor
enum E2ECaptureControls {
    static func run() async {
        let saved = E2E.app.settings.value
        defer { E2E.setOpts { $0 = saved } }
        E2E.setOpts { $0.options.delaySeconds = 0; $0.options.openEditor = true }
        for context in ["region", "freehand", "window", "monitor", "editor", "drag", "text", "toolbar", "style"] {
            await escape(context)
        }
        await visibleTools()
        let cursor = CaptureCursor.crosshair
        if let tiff = cursor.image.tiffRepresentation { try? tiff.write(to: E2E.out.appendingPathComponent("capture-crosshair.tiff")) }
        E2E.record("capture-crosshair-size-hotspot", cursor.image.size == CGSize(width: 24, height: 24)
                   && cursor.hotSpot == CGPoint(x: 12, y: 12) && cursor.image.tiffRepresentation != nil)
    }

    private static func escape(_ context: String) async {
        let name = "capture-escape-\(context)", mark = E2E.markClipboard(), lastRegion = E2E.app.settings.value.lastRegion
        let mode: CaptureStyle
        switch context {
        case "freehand": mode = .freehand
        case "window": mode = .windowPicker
        case "monitor": mode = .monitorPicker
        case "editor": mode = .fullscreen
        default: mode = .region
        }
        E2E.coord.capture(mode)
        guard await E2E.until({ E2E.surface() != nil }), let surface = E2E.surface() else {
            E2E.record(name, false, ["error": "capture did not open"]); return
        }
        let surfaces = E2E.coord.overlay?.e2eSurfaces ?? []
        let view = surface.view, toolbar = view.e2eToolbar
        var target = surface.window, ready = true
        let point = CGPoint(x: 180, y: max(220, view.toolbarBottom + 40))
        switch context {
        case "drag":
            E2E.mouse(.leftMouseDown, point, in: surface)
            E2E.mouse(.leftMouseDragged, CGPoint(x: point.x + 100, y: point.y + 80), in: surface)
            ready = view.session.selectionHole != nil
        case "text":
            view.setTool(.shape(.text)); E2E.click(point)
            let field = E2EEditing.views(view).compactMap { $0 as? NSTextField }.first { $0.isEditable }
            field?.stringValue = "Discard this unfinished annotation"
            ready = view.session.editingTextID != nil && surface.window.firstResponder is NSTextView
        case "toolbar":
            view.setTool(.shape(.rectangle))
            ready = surface.window.makeFirstResponder(toolbar.e2eStyle)
        case "style":
            view.setTool(.shape(.rectangle))
            let clicked = E2E.postClick(toolbar.e2eStyle)
            ready = await E2E.until { toolbar.e2ePopoverShown }
            ready = ready && clicked
            target = toolbar.e2eStyleContents.window ?? surface.window
        default: break
        }
        // Use the application queue, including the popover's own window and local event monitors.
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                                           context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                           isARepeat: false, keyCode: 53) {
                NSApp.postEvent(event, atStart: false)
            } else { ready = false }
        }
        let cancelled = await E2E.until { !E2E.coord.busy && E2E.coord.overlay == nil }
        let closed = surfaces.allSatisfy { !$0.window.isVisible }
        E2E.unchanged(name, mark,
                      extra: ["contextReady": ready, "cancelled": cancelled, "allWindowsClosed": closed],
                      cond: ready && cancelled && closed && view.phase == .ended && view.session.editingTextID == nil
                        && !toolbar.e2ePopoverShown && E2E.app.settings.value.lastRegion == lastRegion)
        if !cancelled { view.cancel(); _ = await E2E.until { !E2E.coord.busy } }
    }

    private static func visibleTools() async {
        guard let fixture = await E2EEditing.open("capture-visible-tool-buttons") else { return }
        let bar = fixture.view.e2eToolbar
        let tools: [(String, Tool)] = [("Select", .select), ("Crop", .crop)] + ShapeKind.allCases.map {
            ($0 == .step ? "Step marker" : $0.rawValue.capitalized, .shape($0))
        }
        var checks = true
        for (title, tool) in tools {
            guard let button = bar.e2eButton(title) else { checks = false; continue }
            let clicked = E2E.postClick(button)
            let selected = await E2E.until { fixture.view.tool == tool && button.state == .on }
            checks = checks && clicked && selected && button.image != nil && button.accessibilityLabel() == title
                && !(button.toolTip ?? "").isEmpty && bar.bounds.contains(button.frame)
        }
        E2E.snapshotNativeView(bar, name: "capture-visible-tools")
        E2E.record("capture-visible-tool-buttons", checks && tools.count == 13,
                   ["tools": tools.count, "buttons": bar.e2eButtons.count])
        fixture.view.cancel(); _ = await E2E.until { !E2E.coord.busy }
    }
}
#endif
