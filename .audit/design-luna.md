# Candidate design: smart eraser and continuous styles

## Problem

`EditorDocument` already gives each annotation drag one undo snapshot. `Renderer` supplies both editor and export pixels, and its effect cache tracks protection overlap only inside each effect's output rectangle. A local eraser needs a surrounding sample ring, so that dependency must be included in cache invalidation and privacy checks. Style sliders currently send one discrete change at a time and are noncontinuous. The design keeps annotation state, gesture history, and pixel rendering with their current owners.

## Usage (caller's view)

The user selects **Smart Eraser**, drags over a small text or object on a simple or gradient background, and sees a local repair preview. Releasing the pointer commits one movable, resizable, undoable annotation. The tool uses local pixels only. It does not claim reliable removal from complex photographs.

The user opens **Style**, sees the current numeric width, opacity, and effect strength, and sees the selected color swatch. Moving a slider updates the selected mark and all display previews at once. Releasing the slider creates one undo step. With no selected mark, the same gesture updates the active tool's remembered style for the next mark and creates no document undo step.

```swift
// App/Sources/EditorSession.swift — existing pointer path, extended for .smartErase.
doc.beginDrag()
let id = doc.addShape(.smartErase, at: start)
drag = .newShape(id)
// Each drag event calls doc.extendShape(id, to: point); refresh() shows the live patch.
// Pointer-up calls doc.endDrag() and refresh(); preview and export use Renderer.

// App/Sources/ToolbarView.swift — style slider tracking.
slider.beginTracking = { editor.session.beginStyleGesture() }
slider.valueChanged = { value in editor.changeStyle { $0.opacity = value } }
slider.endTracking = { editor.session.endStyleGesture() }
```

These are caller sketches, not proposed closures on `NSSlider`. Use a small slider subclass or tracking control that brackets AppKit tracking; its existing target/action remains the value-change path. Keyboard and accessibility changes that do not have a pointer tracking interval stay discrete.

## Shape

### Core types and signatures

```swift
// Packages/ShareXCore/Sources/ShareXCore/Annotation.swift
public enum ShapeKind: String, Codable, CaseIterable, Sendable {
    case rectangle, ellipse, line, arrow, highlighter, blur, pixelate, spotlight
    case smartErase, pen, text, step
    var isEffect: Bool { /* blur, pixelate, spotlight, smartErase */ }
}

// The annotation rectangle is the repair output. Halo size is renderer policy,
// bounded in pixels; it is not user-provided geometry or a serialized cache field.
// Existing two-point geometry keeps move, resize, hit-test, and Codable behavior.

// Packages/ShareXCore/Sources/ShareXCore/EditorDocument.swift
public mutating func beginStyleGesture(to kind: ShapeKind)
public mutating func applyStyleLive(_ change: (inout ShapeStyle) -> Void, to kind: ShapeKind)
public mutating func endStyleGesture()
public mutating func cancelStyleGesture()
```

`EditorDocument` owns one optional style transaction containing the target kind and initial `EditorState`, if a committed selected annotation is being edited. Each live update changes the annotation and remembered tool style without adding history. End records `before` and current state once; cancel restores `before`. No selected committed mark means only the remembered style changes. A pending empty text mark keeps the existing rule: its first text commit includes its style and add in one history entry. Existing `applyStyle` stays the discrete path and must close an open transaction before it records a separate operation.

```swift
// App/Sources/EditorSession.swift
func beginStyleGesture()
func changeStyle(_ change: (inout ShapeStyle) -> Void, continuous: Bool = false)
func endStyleGesture(cancelled: Bool = false)

// App/Sources/Renderer.swift — private cache representation
private struct EffectKey: Hashable {
    let kind: ShapeKind
    let output: PixelRect
    let sample: PixelRect        // output plus a bounded pixel halo for smartErase
    let strength: Double
    let prior: [PixelRect]       // prior protections intersecting sample
    let exceeded: Bool
}
```

Implementation detail: ordinary blur and pixelate set `sample == output`, preserving their current pixels and costs. Smart erasure reads a sanitized, bounded frozen-source sample, reconstructs only the marked rectangle by interpolating opposing edge colors with a smooth transition, and returns a patch for `output`. It is intended for small targets on uniform or gradual backgrounds. No model, service, or dependency is added. Work and allocation are checked before image creation; oversize input or render failure paints the output opaque black and records the same failure mask used by other redactions.

If an earlier protected region intersects the eraser's sample ring, the eraser fails closed for its output rather than use protected pixels as reconstruction input. Keep output and sample bounds distinct. The cache key includes the complete sample bounds and all prior protection intersections there, so moving, resizing, undoing, or changing any relevant protection invalidates the patch. Treat the eraser output as a protection: later effects cannot sample the original source there, and the magnifier must not show the raw source through it. Extend the live overlap guard to the sample dependency while preserving opaque rectangles, blur, and pixelation.

### Responsibility map

- `ShapeKind` and `Annotation`: add the tool, shortcut, defaults, effect classification, toolbar metadata, and accessible label. The rectangle remains the source of truth for the repair area.
- `EditorDocument`: own style gesture begin/update/end/cancel and produce one snapshot for one gesture. The toolbar does not write undo history.
- `EditorSession`: translate slider tracking into the document transaction, refresh every view on each value, and finish the transaction before undo, redo, deletion, tool/selection changes, export, or popover close. Do not reacquire first responder for each value.
- `Renderer`: own bounded halo calculation, sanitized source materialization, local reconstruction, effect keys, memory limits, failures, protection, and the patch shared by live, committed, and export drawing.
- `LiveMarkView`: display the same renderer patch during the drag; extend support and fail-closed overlap behavior. Do not implement a second repair algorithm in the layer.
- `ToolbarView`: use continuous slider events, add current-value labels, mark the current palette swatch selected, and synchronize from selected mark or active tool defaults before the first annotation.

The renderer interface remains a small capability boundary: callers draw annotations and request the existing live patch; they do not know halo size, reconstruction stages, cache format, or filter implementation. The complexity stays behind `Renderer`, and the state change stays behind `EditorDocument`.

### Privacy and output invariants

1. The frozen frame is the only input. Never read a composited window or external source.
2. Erased output is protected from raw-source magnification and later effect sampling, including after move, resize, undo, and redo.
3. Protected pixels in a halo are never used as reconstruction input. Any unsafe or exceeded dependency uses the opaque fallback.
4. Committed preview and export call the same renderer. Live preview uses the same reconstruction function and protection policy.
5. All image dimensions and retained bytes are bounded before allocation. Cache invalidation covers the whole sample region, not just visible output.

### Alternatives considered

| Concern | Candidate | Benefits and cost | Decision |
|---|---|---|---|
| Eraser | Rectangular annotation plus a private renderer patch | Existing hit testing, move, resize, undo, live preview, and export already consume annotation effects. Renderer hides halo policy and cache complexity. Renderer must add one coherent protected-effect implementation. | Choose. It has the shortest integration path and one source of pixels. |
| Eraser | Baked raster delta stored by `EditorDocument` | The reconstructed pixels become ordinary source pixels. But every edit then needs original-pixel storage, compositing order, cache invalidation, and special handling when a patch moves or resizes. Undo snapshots become image-owning and the renderer/export path gets another pixel source. | Reject. It splits ownership and makes existing annotation lifecycle less reliable. |
| Eraser | Separate eraser stroke/overlay subsystem | A stroke can trace irregular targets, but it needs its own hit-testing, move/resize, history, clipping, live patch, and export integration. It exposes two ways to erase and encourages later tools to bypass annotation invariants. | Reject for this brief's local rectangular repair scope. |
| Style history | Document-owned style transaction with live state updates | Toolbar only brackets tracking. The document owns the before-state and commits once; renderer sees ordinary document changes. Small API hides history rules. | Choose. |
| Style history | Buffer preview style in `EditorSession`, apply once on release | Makes history grouping easy, but preview needs a style override through renderer, live layers, and toolbar. That creates temporary presentation state beside canonical annotation style and risks export differing during an open gesture. | Reject. |
| Style history | Coalesce `UndoStack.record` entries by time or gesture token | Reuses the stack but makes unrelated edits subject to generic grouping rules and requires callers to coordinate transaction IDs. This leaks the undo implementation into UI control tracking. | Reject. |

## Native E2E checks

- Drag a repair rectangle over text on flat and linear-gradient fixtures. Assert expected interior output pixels and unchanged exterior pixels; include a complex photograph fixture that records no quality promise.
- Verify pointer motion shows the same repair algorithm as committed render; flatten export and compare its pixel output with the editor renderer.
- Place earlier opaque, blur, or pixelation protection beside and intersecting the halo. Assert raw protected colors never appear in preview, loupe, cache rebuild, or export. Confirm fail-closed output where the halo intersects protection.
- Move and resize the eraser, undo and redo it, and change a nearby protection. Assert the output and cache dependencies follow the current geometry, with bounded cache bytes.
- Drag each slider through multiple values. Assert each intermediate value reaches the selected annotation and all displays; one undo restores the starting style and redo restores the final style. Verify no selected mark updates only the active tool default and pending text retains its grouped add/style behavior.
- Check labels and selected swatch at popover open, after a value change, and after tool/selection changes. Check keyboard change remains one discrete undo step.

## Next implementation step

Add the `smartErase` model case and document style-gesture transaction first, then thread those types into the renderer and slider tracking before running the full native E2E campaign.
