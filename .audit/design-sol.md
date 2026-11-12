# Local repair and continuous style design

## Usage (caller's view)

The user chooses **Smart erase**, drags a rectangle around screenshot text or a small object, and sees an opaque repair from the nearby background. The tool description says: “Repair text and small objects on simple backgrounds.” The result supports selection, move, resize, crop, undo, redo, and export. No source pixels inside the rectangle are used. Textured photographs are outside the quality promise. If no safe background can be read, the rectangle stays covered and the editor reports the repair failure.

The user opens Style and sees selected color buttons, the current numeric values, and a sample on a checkerboard. The sample exists before a mark is drawn. Slider movement updates the selected mark and the sample on every action. One drag creates one undo step. Keyboard and accessibility actions remain discrete steps. Smart erase is always opaque; its irrelevant color, opacity, fill, and strength controls are disabled.

```swift
// Existing tool and geometry lifecycle; no parallel repair command model.
session.setTool(.shape(.smartErase))
session.pointerDown(start, clicks: 1, from: view)
session.pointerDragged(end, from: view)
session.pointerUp(end, from: view)

// A tracking NSSlider brackets the native AppKit tracking loop.
session.beginStyleGesture()
// target-action is continuous while super.mouseDown(with:) tracks:
session.changeStyle { $0.opacity = slider.doubleValue }
session.endStyleGesture() // defer after super.mouseDown, also safe on dismissal

// Export commits an active style edit before reading the document.
session.finish() // end style gesture, commit text, existing Export.flatten
```

The pointer-method names above express the existing lifecycle; implementation should retain the repository's exact event signatures.

## Problem and grounding

`EditorDocument` owns annotation snapshots and per-call style history. `EditorSession` is the only controller shared by display surfaces. `Renderer` already owns both preview/export effects, protection regions, dependency invalidation, failure covers, and bounded caches. `LiveMarkView` draws live effects above committed marks. `ToolbarView` currently sends noncontinuous slider actions. These are the existing ownership seams; a separate image-edit document would duplicate them.

The subtle requirement is a new source-read footprint: repair samples outside its output rectangle. The current `EffectKey.prior` describes only earlier protections inside the output. A halo needs a separate sampling mask and dependency set.

## Shape and signatures

### Annotation and renderer

Add one Codable enum case, `ShapeKind.smartErase`, with rectangular geometry and a unique single-key shortcut. Include it in `isEffect`, toolbar metadata, live rendering, and all exhaustive switches. Treat it as a privacy protection regardless of style opacity. It has no independent strength setting in this version.

Keep these types private inside `Renderer`; callers still ask only to draw an annotation or obtain its live patch:

```swift
private struct EffectKey: Hashable {
    let kind: ShapeKind
    let rect: PixelRect                 // opaque output and dirty region
    let sample: PixelRect               // source allocation/read region
    let strength: Double               // existing blur/pixelate behavior
    let sourceExclusions: [PixelRect]   // protected source inside sample
    let outputExclusions: [PixelRect]   // earlier protections inside rect
    let exceeded: Bool                 // fail closed before work/allocation
}

private func effectPatch(_ a: Annotation, retain: Bool = true)
    -> (image: CGImage, rect: CGRect)? // existing public-to-renderer path

private func smartErasePatch(_ key: EffectKey) -> CGImage? {
    // Validate allocation, gather bounded unprotected ring samples,
    // fit background, emit opaque pixels; nil means existing failure cover.
    fatalError("not implemented")
}
```

`Renderer.synchronize` derives the full protection list once, then effect dependencies in annotation order. For repair, `sourceExclusions` includes **all other protection annotations**, before and after this mark, intersected with the sampling region. `outputExclusions` includes only earlier protections intersected with the output. Blur and pixelate retain their current earlier-protection source policy and output clipping. Do not reuse one list for both meanings.

The repair kernel is a private CPU operation in `Renderer.swift`, or a small internal `SmartErase.swift` if readability requires it. It reads an opaque RGBA bitmap through a narrow closure or validated bitmap view. No AppKit view, annotation, cache, or undo state enters the kernel.

Use a fixed narrow ring outside the rectangle, clipped to source bounds, with a capped, evenly distributed sample grid. Never sample inside the output. Skip protected pixels **before reading them**, rather than fitting opaque black sanitization into the background. Fit RGB planes in normalized coordinates, perform a fixed small number of robust residual-reweighting passes, clamp output channels, and write alpha 255. This reproduces a flat background and a linear gradient while reducing influence from nearby text. Do not introduce synthesis searches, model inference, or an unbounded convergence loop. With too few valid samples or a singular fit, use a robust constant from valid samples; with no valid samples, return failure.

Read work is bounded by a fixed sample cap (for example 512), and output work is linear in the already bounded patch pixels. Validate both sample and output allocation before creating a bitmap. Retain the existing committed 64 MiB/128-entry cache, 16-megapixel effect limit, and 16 MiB live-patch limit. Use checked dimensions and byte counts. Live repair shares the exact kernel and cache-key policy; no asynchronous worker or second source snapshot is needed for this scope.

The key contains both footprints and the actual exclusion rectangles, so moving, resizing, undoing, or changing any halo protection invalidates the repair. A later redaction inside an earlier repair's halo must invalidate it too. Including only prior marks is unsafe: the repair can otherwise move raw pixels from that later protected region into an unprotected output area.

### Style gesture history

```swift
// EditorDocument additions. State remains owned by the document.
public mutating func beginStyleGesture(to kind: ShapeKind)
public mutating func endStyleGesture()
public mutating func applyStyle(_ change: (inout ShapeStyle) -> Void,
                                to kind: ShapeKind) // existing API, one mutation path

private enum StyleGesture {
    case annotation(id: Int, kind: ShapeKind, before: EditorState)
    case pendingText(id: Int, kind: ShapeKind)
    case toolDefault(kind: ShapeKind)
}
private var styleGesture: StyleGesture?

// EditorSession additions adapt UI events to the document owner.
func beginStyleGesture()
func endStyleGesture()
```

At begin, capture the target identity and kind once. Repeated begin is a no-op while tracking; repeated end is a no-op. `applyStyle` remains the only implementation that updates both remembered defaults and a mark. During an active gesture, it targets the captured mark and omits per-action history. End records one before/after pair for `.annotation`. `.toolDefault` changes have no document history. `.pendingText` style stays with the first text commit, as it does today. An unchanged drag records no history and does not clear redo.

Keep style tracking separate from `dragOrigin`; using geometry drag state would invoke degeneracy cleanup and pending-text rules that are wrong for a slider. Finish style history at document mutation boundaries (undo, redo, deletion, geometry begin, text commit, crop mutation) and session target/lifecycle boundaries (tool, selection, popover dismissal, finish, cancellation). A captured target prevents accidental edits to a new selection if a boundary is missed. No second before-state is stored in `EditorSession` or `ToolbarView`.

A small `TrackingSlider` subclass sets `isContinuous = true`, calls begin before `super.mouseDown(with:)`, and end in `defer`. Target-action calls the existing style mutation method. Actions outside mouse tracking do not begin a group. `changeStyle` refreshes every display but restores first responder only for a discrete action; continuous tracking must not lose the slider. Popover dismissal ends the group and restores focus. Keep text finalization out of every intermediate event.

`ToolbarView.sync` derives labels, selected swatch state, and the preview from `doc.selected?.style ?? doc.style(for: kind)`. The preview draws the current color/opacity on a checkerboard plus a representative line or text sample. It stores no duplicate style. Show current hue and opacity on the Style button or adjacent chip so the active defaults remain visible when the popover is closed.

## Responsibility map

| Owner | Responsibility |
|---|---|
| `Annotation.swift` | One shape kind, effect classification, rectangular lifecycle, defaults |
| `EditorDocument.swift` | Fixed style target, live mutations, one history entry |
| `EditorSession.swift` | Native gesture routing, transaction boundaries, shared-display refresh |
| `Renderer.swift` | Sampling policy, repair pixels, privacy dependencies, failure covers and cache |
| `EditorLayers.swift` | Existing effect live patch path and overlap guard, circular magnifier chrome |
| `ToolbarView.swift` | Native tracking controls, derived value labels, selected swatches, style sample |
| Existing settings/delivery owners | Preserve saved opt-outs, show effective save destination, crisp success-only sound |

The public surface hides repair fitting, sample validity, exclusions, cache invalidation, and history snapshots. No caller coordinates image stages or writes history itself. This is a deeper interface with the existing short draw call chain.

## Alternatives considered

1. **Chosen: derived rectangular effect plus a model-owned style gesture.** A repair annotation is a recipe over the frozen source. Undo, move, export, and cache ownership follow the current effect model. Style updates mutate the same document and use its history owner.
2. **Destructive repaired-source layers plus a UI draft style.** Commit repaired pixels into a new source image and have the toolbar preview a local draft until mouse-up. This hides the fitting algorithm, but makes move/resize require stored source reconstruction, snapshots become image-sized, and the live selected mark needs a second render override. It also creates two owners for style and two image histories. Reject for split ownership and greater caller coordination.
3. **Persistent composited patch graph plus generic document transactions.** Each repair samples a rendered prefix of earlier marks, and all drag/style/text operations use one generic transaction stack. This can support future image editing, but dependency recursion, cycle/order policy, and cache memory are much larger than this need. Later source protections still require explicit halo exclusion. A generic transaction also obscures the existing pending-text contract. Reject for scope and exposed policy.

We accept limited photo quality in exchange for deterministic local execution with no network or downloaded model. We accept a small fixed fitting cost on pointer movement in exchange for identical preview and exported behavior. No provisional async patch can arrive after undo or view teardown.

## Privacy and failure contract

- Include repair rectangles in `protectionBounds` and `sourceIsProtected`, so the raw-source magnifier cannot show removed content.
- Preserve earlier opaque rectangles, blur, pixelation, and repairs through output clipping. Extend `liveGuard` for the new effect and invalidate all affected dependent outputs during drag.
- Materialization failure, dependency overflow, unsupported allocation, or unavailable safe source produces the existing opaque failure cover in live, committed, and exported rendering.
- Source ring masks include protections of every order. A repair's own output is never a sample. Neighboring repairs therefore do not form render dependencies on one another's output.
- Crop and scale changes derive fresh pixel bounds and invalidate all effect materialization as today. No repaired bitmap is persisted in settings.

## Native validation contract

Add native E2E fixtures for (1) text/object over a uniform background, (2) text over horizontal and diagonal RGB gradients, (3) selected regions at image edges, and (4) a busy background showing the stated limitation without claiming a perfect reconstruction. Read actual output pixels, not only annotation state.

Privacy fixtures place earlier and later opaque fills, blur, pixelation, and repair inside the halo and output. Compare two source images that differ only under these masks: repaired output outside the masks must match. Then move/resize the masks, undo/redo, force materialization failure, drag through overlaps, and verify magnifier suppression. Compare live settled pixels, committed pixels, and exported PNG pixels. Assert cache byte/entry limits through existing seams.

Drive an actual native slider mouse sequence and observe an intermediate selected-mark pixel change before release. Verify one undo restores the complete pre-drag style, redo restores the final style, a no-op drag adds no history, and keyboard changes remain separate. Test tool defaults without a mark, selected swatch/value/sample feedback, cross-display refresh, popover dismissal, and pending empty text.

After all five user features are implemented, run the full native `scripts/e2e.sh` campaign. Inspect `unverifiable` results; process success alone is insufficient. Verify default/missing settings save to the effective destination, explicit false persists, and the new sound occurs only after every requested delivery succeeds. A Windows-only run cannot establish native macOS E2E success.

## Synthesis and reconciliation

This is one independent candidate; the parent owns synthesis. No product code was changed and no tests were run. First implementation unit: add the annotation case and renderer footprint/mask separation, then the bounded repair kernel, before wiring the toolbar and style transaction.
