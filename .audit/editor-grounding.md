# Editor implementation grounding

The user wants circular capture magnification, immediate style feedback, a local smart eraser, default saving, and a crisp completion sound. This report records source inspection only. No tests were run and no product code was changed.

## Current ownership

- `Packages/ShareXCore/Sources/ShareXCore/Annotation.swift` owns `ShapeKind`, keyboard mappings, effect classification, annotation geometry, and per-tool styles. A rectangular `smartErase` shape fits the existing two-point geometry, hit testing, move, resize, and Codable model.
- `Packages/ShareXCore/Sources/ShareXCore/EditorDocument.swift` owns annotation state and snapshot undo. A pointer drag already records one history entry. Selection, active tool, and remembered styles are outside undoable `EditorState`.
- `App/Sources/EditorSession.swift` shares one document and renderer across display surfaces. It owns gesture state, style target, text editing, tool transitions, and completion. `refresh()` synchronizes renderer dependencies and then all views.
- `App/Sources/EditorLayers.swift` separates the frozen frame, committed annotations, live marks, and capture chrome. Committed annotations redraw only changed regions. The live mark is drawn above the committed annotation layer.
- `App/Sources/Renderer.swift` supplies both editor pixels and exported pixels. `Export.flatten` draws the frozen source followed by the same renderer. This is the correct integration point for erasure.

## Smart eraser invariants

A bounded rectangular edge reconstruction can reuse the current annotation lifecycle and patch cache. This is a proposed implementation, not verified image quality. Extend all exhaustive `ShapeKind` switches and explicitly include the tool in `LiveMarkView.supports`, its patch drawing branch, effect classification, toolbar metadata, and renderer protection handling.

Current blur and pixelate patches are derived from the frozen source. They do not sample the composited annotation layer. Earlier protection is blacked out before filtering, and its overlap is excluded when drawing the patch. Protection currently means blur, pixelate, or a fully opaque filled rectangle. Failure is covered with opaque black, including export and live rendering. Effect opacity is intentionally ignored.

The current `EffectKey.prior` contains protected overlaps with the output rectangle only. An eraser that reads a surrounding ring must track protected overlaps with its entire sampling area. Otherwise a neighboring protection can change without invalidating the eraser cache, or raw protected source pixels can enter the result. Keep output bounds separate from sampling bounds. Exclude or sanitize protected ring pixels before reconstruction. Bound dimensions, work, and retained bytes before allocation.

Include smart erasure in the protection model if the removed source must stay hidden. This also makes `EditorView.setMagnifier` suppress the raw-source loupe over removed content through `Renderer.sourceIsProtected`.

`LiveMarkView` sits above later committed annotations. `Renderer.liveGuard` presently covers intersecting protections during drag to prevent a live patch from exposing protected source. Extend that guard and dependency checks to smart erasure. Preserve protection across move, resize, undo, redo, lower-strength changes, and failed materialization.

Renderer limits currently include 64 MiB committed patch storage, 128 cache entries, 16 megapixels per committed effect, and 16 MiB live patch storage. Scale changes clear all effect dependencies and cached patches. Session completion releases transient renderer and layer resources.

## Continuous style feedback

`ToolbarView.buildStyle` explicitly sets all three sliders to `isContinuous = false`. Palette buttons already apply colors immediately. `EditorSession.changeStyle` refreshes all surfaces, so enabling continuous events reaches the renderer without another rendering channel.

However, `EditorDocument.applyStyle` records one undo snapshot per call. Continuous sliders need a style transaction with one before-state, live style mutations, and one commit on tracking end. A slider subclass can bracket `super.mouseDown` with begin and end callbacks while target-action handles intermediate values. Keyboard and accessibility changes outside tracking should remain discrete changes. Keep this transaction separate from geometry drag state.

Finish an active style transaction before undo, redo, tool or selection change, deletion, export, or cancellation. Avoid stealing first responder on each continuous value update. Popover dismissal should finish the transaction and restore focus. Preserve the existing rule that editing an uncommitted empty text mark adds no separate undo step. Tool defaults remain outside undo history, as they do now.

## Magnifier, settings, and output

`ChromeView` in `EditorLayers.swift` owns a 120-point square loupe that displays 15 by 15 source pixels at 8x. It already clips through `magnifier.masksToBounds`; a circular outer clip and matching rim can preserve nearest-neighbor sampling, center pixel marker, placement, and detached coordinate label. Preserve `contentsRect` orientation and multi-display sample offsets in `EditorView.setMagnifier`.

`AppSettings.saveToFile` already defaults to true. Missing saved keys also use true, while an explicit stored false is preserved. Empty `saveFolder` already means `~/Pictures/ShareX`. `CaptureCoordinator.deliver` uses these settings to create `ExportDelivery`; clipboard and file writes are independent and failed outputs can be retried without duplicating completed writes.

`ExportDelivery.finish` plays `Tink` only after all requested outputs succeed and respects `playSound`. A replacement capture sound belongs at this point. Preserve this success condition and the E2E sound seam. The current seam counts success requests without exercising audible playback.

## Existing validation entry points

`scripts/e2e.sh` runs the native application harness compiled with `SHAREX_E2E`. `App/Sources/E2E.swift` drives real coordinator, overlay events, pasteboard reads, saved PNG checks, and settings relaunch. Relevant suites include `E2EPrivacy`, `E2ERedaction`, `E2ERenderer`, `E2EStylePersistence`, `E2ELoupe`, `E2EExport`, and `E2EEditing`. Results can contain `unverifiable` checks, so a successful process exit alone does not establish complete native coverage.

Next implementation checks should cover an actual slider gesture with intermediate pixel feedback and one undo, smart erasure on uniform and gradient fixtures, protected sampling-ring neighbors, overlap during drag, export equality, failure fallback, default versus stored saving preferences, and successful versus failed delivery sound behavior. Run the full native E2E campaign after all requested features are implemented.
