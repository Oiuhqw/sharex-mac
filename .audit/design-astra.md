# Candidate: bounded background repair and document-owned style gestures

## Usage (the contract)

Select **Smart eraser**, then drag a rectangle around screenshot text or a small object. The rectangle is replaced with an estimate from its surrounding background. Move, resize, delete, undo, redo, crop, and export use the normal annotation commands. Help text says: “Remove small objects on plain or smooth backgrounds.” This does not claim arbitrary photo repair. An unsupported or failed repair becomes an opaque cover with an actionable status; it never falls back to the original pixels.

Open Style before drawing to see the selected color, a checkerboard preview, and numeric size and opacity. Drag a slider to update the preview and selected mark immediately. Releasing it creates one undo step for the selected mark. Unselected tool defaults stay outside document undo, as today. Swatches have a selected state. Controls that cannot affect the tool are disabled; smart erasure is always opaque.

```swift
// Toolbar: AppKit performs tracking and emits intermediate target-actions.
slider.trackingBegan = { session.beginStyleEdit() }
slider.valueChanged = { session.changeStyle { $0.opacity = slider.doubleValue } }
slider.trackingEnded = { session.endStyleEdit() }

// Existing geometry lifecycle also drives smart erase.
session.setTool(.shape(.smartErase))
// mouseDown -> doc.beginDrag/addShape; mouseDragged -> extendShape; mouseUp -> endDrag

// Preview and export retain the existing renderer entry point.
renderer.draw(doc, in: context)
```

## Grounding

Read Annotation, EditorDocument, EditorSession, ToolbarView, Renderer, EditorLayers, EditorView, DesktopImageSource, native renderer E2E, and `.audit/editor-grounding.md`. The document owns small annotation snapshots. The session owns interactions across display views. The renderer owns frozen pixels, protection dependencies, and bounded effect caches. LiveMarkView renders above committed marks, so its overlap guard remains necessary. `applyStyle` currently records on every call; `NSSlider` currently sends only final values.

## Shape and ownership

```swift
// ShareXCore: reuse Annotation geometry and Codable representation.
enum ShapeKind { /* existing cases */ case smartErase }

// EditorDocument owns the snapshot and immutable target of the style gesture.
private struct StyleEdit {
    let before: EditorState
    let kind: ShapeKind
    let selectedID: Int?
}
private var styleEdit: StyleEdit?
mutating func beginStyleEdit(for kind: ShapeKind) { /* not implemented */ }
mutating func endStyleEdit() { /* not implemented */ }
mutating func applyStyle(_ change: (inout ShapeStyle) -> Void, to kind: ShapeKind) {
    // not implemented: same mutation path for discrete and continuous changes;
    // active gesture suppresses per-event history, then end records once.
}

// Renderer-private: output clipping and input protection have different meanings.
private struct EffectKey: Hashable {
    let kind: ShapeKind
    let rect: PixelRect
    let samplingRect: PixelRect
    let strength: Double
    let priorOutput: [PixelRect]
    let excludedSamples: [PixelRect]
    let exceeded: Bool
}

// One app-internal repair helper owns sampling, fitting, and patch production.
enum BackgroundRepair {
    static func patch(source: DesktopImageSource, output: PixelRect,
                      sampling: PixelRect, excluded: [PixelRect],
                      scale: CGFloat) -> CGImage? { /* not implemented */ }
}
```

The helper samples a bounded ring outside the erase rectangle and estimates a robust RGB affine plane. This reproduces flat and simple gradient backgrounds without copying foreground pixels inside the erased rectangle. Reject outlier samples before the final fit. Require enough valid, spatially distributed samples; reject singular fits or high residuals. At display edges, valid samples from available sides may suffice if they still constrain the plane. A failed fit uses the existing opaque failure cover.

Bound work independently of rectangle area: at most 256 nearest-neighbor source sample pixels and a small generated gradient patch, no full-desktop raster and no iterative image-size solver. Each sample must be fully inside a captured tile and outside exclusion masks; do not infer display gaps as black background. A compact patch can be linearly scaled because it represents a smooth field. Use smart-eraser interpolation explicitly rather than the existing nearest-neighbor effect default. Retain the existing cache limits and live patch limit. The helper does not own caches or annotation state. Do not introduce a background job system for this bounded operation.

The document stores only rectangle and kind. A moved rectangle repairs its new location. Undo restores geometry; renderer dependencies rebuild the appropriate patch. Crop and display-scale changes follow existing renderer invalidation.

## Privacy contract

1. Build the document protection list before building effect keys. Smart eraser, blur, pixelate, and fully opaque filled rectangles protect their output regions.
2. For smart erasure, `excludedSamples` intersects the full sampling ring with **all** protections, including later marks. The erased interior itself is never a sample. Later protection matters: otherwise an earlier eraser can copy a later-covered secret from its halo into visible output.
3. Keep `priorOutput` separately for compositing. Clip prior protected output as the renderer does today. Do not use all-order exclusions as output clipping: later marks still render in their normal order.
4. Key every geometric sample exclusion, even if it does not overlap the output. Moving, deleting, restyling, undoing, or redoing a neighboring protection invalidates every affected patch. Exceeding dependency limits produces a cover, never an incomplete mask.
5. Add smart erasure to raw-source loupe protection and downstream blur/pixelate sanitization. Protect removed source even when a repair fails.
6. Preserve the live overlap guard. An older live eraser must not paint over later committed protections. All-order sample exclusion plus synchronized cache invalidation prevents halo disclosure; the guard prevents layer-order disclosure.
7. There is no network call, model download, retained source copy in history, or source sampling from an already composited scene.

## Style gesture lifecycle

Use a small NSSlider subclass to bracket `super.mouseDown(with:)` with begin/end and `defer`. Set `isContinuous = true`; retain target-action for every value. Do not restore the editor first responder during live updates. Keyboard and accessibility actions outside mouse tracking remain discrete undo changes. One document-owned gesture snapshot fixes the target kind and annotation ID. Repeated begin/end is harmless. End the gesture before a geometry drag, tool/selection change, undo, redo, deletion, export, or popover dismissal. Session cancellation discards the document. Pending text retains its existing rule: first committed text owns its initial style, with no separate empty-text undo entry.

Keep the style snapshot distinct from `dragOrigin`: geometry resize needs the original coordinates, while style editing needs a stable style target. Both are private to EditorDocument. Session transitions prevent concurrent edits. A popover preview reads the same selected style or remembered tool style used to draw the mark; it does not keep a second style value.

## Alternatives and choice

- **Chosen eraser: geometric annotation with lazy bounded background estimation.** Hides sampling and repair in one helper and retains existing document/renderer/export paths. Accept limited backgrounds for deterministic cost and simple move/undo behavior.
- **Rejected eraser: composited bitmap edit with stored repaired patch.** Can include other drawn annotations, but needs raster payload history, coordinate transforms on move, ordering rules, source provenance, and patch regeneration. It exposes more policy to document and export callers and breaks the cheap snapshot model.
- **Rejected eraser: full-resolution diffusion/inpainting each drag.** Can handle more texture but requires iterative work proportional to area, preview/export convergence rules, cancellation, and job ownership. It exceeds this local screenshot requirement.
- **Chosen style history: mutate the document live, record one private before-state.** The existing renderer sees the current authoritative state. One small transaction hides history grouping.
- **Rejected style history: toolbar-owned draft with commit-on-release.** Requires a second rendering state, target synchronization across displays, and independent preview/export behavior. Its small history API hides less of the actual interaction complexity.

Red-flag screen: one writer for annotations/history, one renderer for export and preview, no importable repair stages, no bitmap history, no parallel style draft, and no caller-managed cache invalidation.

## Required validation

- Core: many intermediate style updates produce one selected-mark undo; redo restores final style; no-op creates no entry; default-only changes create no entry; switch/close/undo boundaries commit once; pending text behavior remains correct.
- Native E2E: real slider drag renders an intermediate color/opacity state before mouse-up; selected swatch, numeric label, and blank-canvas preview agree; one undo restores the starting rendered pixels.
- Native E2E: known text on a flat and gradient source is removed; compare patch pixels with known unobscured backgrounds at 1x and 2x. Move/resize/undo/redo/crop/export produce coherent images.
- Privacy metamorphic E2E: two sources differing only under protections produce identical eraser output. Cover both earlier and later protections, halo-only overlap, reordered marks, cached results, live movement, and protection removal/undo. Verify raw-source magnifier suppression.
- Native E2E: allocation/dependency/insufficient-sample failures cover instead of exposing source; cache bytes stay bounded; multi-display seams and missing-display gaps do not supply invalid samples. Run the full existing native E2E campaign after implementation.

## Synthesis and next step

This is one candidate, not the panel synthesis. No product code or tests were changed or run. Start with document style grouping and the renderer's separate output/sampling dependency keys, then implement the bounded repair helper. Record any algorithm or API deviation here when accepted by the orchestrator.
