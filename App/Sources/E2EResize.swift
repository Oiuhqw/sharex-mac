#if SHAREX_E2E
import AppKit
import ShareXCore

/// Regression coverage for the actual mouse-event state machine. Geometry-only tests cannot catch
/// a view accidentally feeding each normalized rectangle back into the next resize event.
@MainActor
enum E2EResize {
    static func run() async {
        let before = E2E.app.settings.value
        defer { E2E.setOpts { $0 = before } }
        E2E.setOpts {
            $0.options = CaptureOptions()
            $0.options.showMagnifier = false
            $0.toolStyles = [:]
            $0.saveToFile = true
            $0.saveFolder = E2E.saved.path
            $0.playSound = false
        }
        for handle in [Handle.right, .bottomRight] {
            await crop(handle)
            await annotation(handle)
        }
        await releaseEndpoints()
        await lassoReleaseEndpoint()
    }

    private static func crop(_ handle: Handle) async {
        let corner = handle == .bottomRight
        let name = corner ? "crop-corner-cross-reverse" : "crop-edge-cross-reverse"
        var checks = false
        let w = E2E.px(480), h = E2E.px(corner ? 380 : 300)
        if let clip = await E2E.presetCapture(name, w: w, h: h, edit: {
            guard let s = E2E.surface(), let original = s.view.doc.state.crop else { return }
            s.view.setTool(.crop)
            let start = handle.point(on: original)
            let points = corner
                ? [CGPoint(x: 50, y: 50), .zero, CGPoint(x: 120, y: 120), CGPoint(x: 580, y: 480)]
                : [CGPoint(x: 50, y: start.y), CGPoint(x: 0, y: start.y), CGPoint(x: 120, y: start.y), CGPoint(x: 580, y: start.y)]
            var tracked = true
            E2E.mouse(.leftMouseDown, start, in: s)
            for point in points.dropLast() {
                E2E.mouse(.leftMouseDragged, point, in: s)
                let expected = Geometry.clamp(handle.resize(original, by: Offset(from: start, to: point)), to: s.view.bounds0)
                tracked = tracked && s.view.doc.state.crop == expected
            }
            E2E.mouse(.leftMouseUp, points.last!, in: s)
            let final = s.view.doc.state.crop
            tracked = tracked && final == Geometry.clamp(handle.resize(original, by: Offset(from: start, to: points.last!)), to: s.view.bounds0)
            let oneStep = s.view.doc.history.undoStates.count == 1
            s.view.undo()
            let undone = s.view.doc.state.crop == original
            s.view.redo()
            checks = tracked && oneStep && undone && s.view.doc.state.crop == final
        }) {
            E2E.record(name, clip.ok && checks, clip.info.merging(["trackedEveryEventAndUndoRedo": checks]) { $1 })
        }
    }

    private static func annotation(_ handle: Handle) async {
        let corner = handle == .bottomRight
        let name = corner ? "annotation-corner-cross-reverse" : "annotation-edge-cross-reverse"
        var checks = false
        if let clip = await E2E.regionCapture(name, edit: {
            guard let s = E2E.surface() else { return }
            s.view.setTool(.shape(.rectangle))
            E2E.drag(CGPoint(x: 150, y: 150), CGPoint(x: 300, y: 250))
            guard let original = s.view.doc.selected else { return }
            s.view.setTool(.select)
            let start = handle.point(on: original.bounds)
            let points = corner
                ? [CGPoint(x: 130, y: 130), CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 180), CGPoint(x: 340, y: 290)]
                : [CGPoint(x: 130, y: start.y), CGPoint(x: 100, y: start.y), CGPoint(x: 200, y: start.y), CGPoint(x: 340, y: start.y)]
            var tracked = true
            E2E.mouse(.leftMouseDown, start, in: s)
            for point in points.dropLast() {
                E2E.mouse(.leftMouseDragged, point, in: s)
                let expected = original.resized(handle, by: Offset(from: start, to: point))
                tracked = tracked && s.view.doc.selected == expected
            }
            E2E.mouse(.leftMouseUp, points.last!, in: s)
            let final = s.view.doc.selected
            tracked = tracked && final == original.resized(handle, by: Offset(from: start, to: points.last!))
            let oneStep = s.view.doc.history.undoStates.count == 2
            s.view.undo()
            let undone = s.view.doc.selected == original
            s.view.redo()
            checks = tracked && oneStep && undone && s.view.doc.selected == final
        }) {
            E2E.record(name, clip.ok && checks, clip.info.merging(["trackedEveryEventAndUndoRedo": checks]) { $1 })
        }
    }

    private static func releaseEndpoints() async {
        for kind in [ShapeKind.rectangle, .pen] {
            let name = "release-endpoint-\(kind.rawValue)"
            var checks = false
            if let clip = await E2E.regionCapture(name, edit: {
                guard let s = E2E.surface() else { return }
                s.view.setTool(.shape(kind))
                let start = CGPoint(x: 150, y: 150), middle = CGPoint(x: 200, y: 200), end = CGPoint(x: 250, y: 250)
                E2E.mouse(.leftMouseDown, start, in: s)
                E2E.mouse(.leftMouseDragged, middle, in: s)
                E2E.mouse(.leftMouseUp, end, in: s)
                guard let mark = s.view.doc.selected else { return }
                checks = mark.start == start && mark.end == end
                if kind == .pen { checks = checks && mark.points == [start, middle, end] }
                s.view.undo()
                checks = checks && s.view.doc.annotations.isEmpty
                s.view.redo()
                checks = checks && s.view.doc.selected == nil && s.view.doc.annotations == [mark]
                // No-drag clicks still discard accidental pen/rect marks instead of adding duplicates.
                s.view.setTool(.shape(kind))
                let click = CGPoint(x: 350, y: 350)
                E2E.mouse(.leftMouseDown, click, in: s)
                E2E.mouse(.leftMouseUp, click, in: s)
                checks = checks && s.view.doc.annotations == [mark] && s.view.doc.history.undoStates.count == 1
            }) {
                E2E.record(name, clip.ok && checks, clip.info.merging(["releaseAppliedAndClickUnchanged": checks]) { $1 })
            }
        }

        var moved = false
        if let clip = await E2E.regionCapture("release-endpoint-move", edit: {
            guard let s = E2E.surface() else { return }
            s.view.setTool(.shape(.rectangle))
            E2E.drag(CGPoint(x: 150, y: 150), CGPoint(x: 300, y: 250))
            guard let original = s.view.doc.selected else { return }
            s.view.setTool(.select)
            // On the outline but outside every resize handle.
            E2E.mouse(.leftMouseDown, CGPoint(x: 160, y: 150), in: s)
            E2E.mouse(.leftMouseDragged, CGPoint(x: 180, y: 170), in: s)
            E2E.mouse(.leftMouseUp, CGPoint(x: 200, y: 190), in: s)
            moved = s.view.doc.selected == original.moved(by: Offset(dx: 40, dy: 40))
        }) {
            E2E.record("release-endpoint-move", clip.ok && moved, clip.info.merging(["releaseApplied": moved]) { $1 })
        }

        var cropped = false
        if let clip = await E2E.presetCapture("release-endpoint-crop", w: E2E.px(80), h: E2E.px(80), edit: {
            guard let s = E2E.surface() else { return }
            s.view.setTool(.crop)
            E2E.mouse(.leftMouseDown, CGPoint(x: 200, y: 200), in: s)
            E2E.mouse(.leftMouseDragged, CGPoint(x: 240, y: 240), in: s)
            E2E.mouse(.leftMouseUp, CGPoint(x: 280, y: 280), in: s)
            cropped = s.view.doc.state.crop == CGRect(x: 200, y: 200, width: 80, height: 80)
        }) {
            E2E.record("release-endpoint-crop", clip.ok && cropped, clip.info.merging(["releaseApplied": cropped]) { $1 })
        }
    }

    private static func lassoReleaseEndpoint() async {
        let name = "release-endpoint-lasso", sentinel = E2E.markClipboard()
        E2E.coord.capture(.freehand)
        guard await E2E.until({ E2E.surface() != nil }), let s = E2E.surface() else {
            E2E.record(name, false, ["error": "no overlay"]); return
        }
        await E2E.wait(100)
        let points = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 200, y: 300)]
        E2E.mouse(.leftMouseDown, points[0], in: s)
        E2E.mouse(.leftMouseDragged, points[1], in: s)
        E2E.mouse(.leftMouseUp, points[2], in: s)
        guard s.view.phase == .ended, s.view.lasso == points else {
            E2E.esc()
            _ = await E2E.until({ !E2E.coord.busy })
            E2E.record(name, false, ["error": "release vertex was dropped"]); return
        }
        guard await E2E.until({ !E2E.coord.busy }) else {
            E2E.record(name, false, ["error": "stuck busy"]); return
        }
        if let clip = E2E.checkClipboard(name, since: sentinel, w: E2E.px(200), h: E2E.px(200)) {
            E2E.record(name, clip.ok, clip.info)
        }
    }
}
#endif
