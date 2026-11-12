# Capture improvement design contract

The user wants a circular magnifier, clear live color and opacity feedback, a magic or smart eraser, file saving enabled by default, and a crisper capture sound.

## Grounding

EditorDocument owns small undoable annotation snapshots. EditorSession owns all pointer and style commands across displays. Renderer and LiveMarkView render effects from frozen tiles, with bounded patch caches. Export uses the same renderer. ToolbarView currently uses noncontinuous sliders and unselected text color buttons. AppSettings.saveToFile is already true and the decoder preserves explicit false. ExportDelivery plays Tink only after all requested outputs succeed.

Renderer.EffectKey.prior currently stores only protected overlaps within the effect output rectangle. A smart eraser that samples a halo must track protection over that entire halo for sampling and cache invalidation. It must preserve existing opaque rectangles, blur, and pixelation. The magnifier reads raw source, so erased regions must also suppress raw source sampling. LiveMarkView draws active effects above committed marks and needs its overlap guard.

## Scope

Prefer a local rectangular repair for screenshot text and small objects on simple or gradient backgrounds. Avoid a network service, model download, or new dependency. Keep undo, move, resize, crop, and export coherent. Do not promise arbitrary photo object removal. Continuous style controls need one undo step per pointer gesture, a visible current value, selected swatches, and a preview even before drawing. Preserve explicit saving opt-outs while exposing the actual destination in the editor. Keep success-only sound semantics.

## Candidate artifact

Write usage first, then types and signatures, responsibility map, and alternatives. Produce at least two structurally distinct designs for eraser rendering and style gesture history. Read the repository to validate assumptions. Do not implement product code. Use a private candidate document under .audit.

## Rubric

1. Complete user interaction and honest eraser capability.
2. Preservation of privacy protections through preview, cache, move, undo, and export.
3. Small coherent interfaces and one state owner.
4. Bounded CPU and memory work during pointer motion.
5. Native E2E checks that prove rendered pixels and undo behavior.
