# macOS developer review, round 2

I checked every round 1 item against the code itself, not against `fixes-round1.md`.
Correction to round 1: I said the box had no Swift toolchain. That was wrong. It is at `/tmp/swift-6.0.3-RELEASE-ubuntu22.04` and is simply not on PATH.

## Build and test results (run this round)
- `swift test --package-path Packages/ShareXCore`: **39 tests, 0 failures, exit 0.**
- `swiftc -parse` on each `App/Sources/*.swift`: **every file parses.** This checks syntax only. AppKit, ScreenCaptureKit and CoreImage cannot be typechecked on Linux, so nothing below about types or concurrency has been compiled.

## Round 1 items
| ID | Status | Evidence |
|---|---|---|
| B1 tuple `if let` | verified | A `Preset` struct is used, with `if let preset, preset.displayID != …` (OverlayController). |
| B2 ScreenCapture isolation | verified | It is now a `@MainActor enum`, so SC objects never cross actors. |
| B3 focus return | verified | `previousApp` is recorded in `show()`; `close()` calls `activate()` on it, or `NSApp.hide` when it is nil. |
| B4 CI blur/pixelate + cache | verified, with new issues | The CI path is correct (see (b)). Blur strength and cache thrash are listed as N-R2-2 and N-R2-3. |
| S1 `path: .` | verified | The core lives in `Packages/ShareXCore`, and project.yml points there. |
| S2 signing | verified | Uses `Local.xcconfig` (git-ignored) plus `.example`, `Apple Development`, Automatic. |
| S3 error mapping | verified | Only `SCStreamError.userDeclined` becomes `.noPermission`. |
| S4 colour space | verified | `colorSpaceName = sRGB` is set in `baseConfig`, and CI renders in `frame.colorSpace`. |
| S5 teardown | verified | The contentView release is deferred to the next main-queue turn. See N-R2-5 for a Swift 6 concern. |
| S6 cursor | verified | `resetCursorRects` sets a crosshair over the view and an arrow over the toolbar, and is invalidated on layout and reset. The old push/pop is gone. |
| S7 multi-screen | verified | `editorDidEnterEditing` sets `ignoresMouseEvents` on the other overlays. |
| S8 shadow scale | verified | `DecorationLayout(…, scale:)` multiplies `shadowBlurPoints` and `shadowOffsetPoints` by the scale. |
| S9 main menu | verified [UNVERIFIED runtime] | See (c). |
| S10 Esc/Return in the text field | verified | `doCommandBy` commits on `cancelOperation:` and `insertNewline:`. Esc commits rather than discards, which I accept. |
| S11 toolbar fall-through | verified | `ToolbarView` swallows mouseDown, mouseDragged, mouseUp and rightMouseDown. |
| S12 right-click | verified | With marks present, it deletes the mark under the cursor. With no marks, it resets selection, or cancels for fixed-area captures. |
| S13 toolbar width | partly fixed | The toolbar has two rows and a vertical fallback. In canvas mode it can still be clipped (N-R2-4). |
| S14 cross-display region | deferred: **agree** | The README states the limit and points to Fullscreen. |
| N1 activation policy | verified | `setActivationPolicy` is removed. |
| N2 Task hop | rejected: **agree** | It is harmless. |
| N3 parallel freeze | deferred: **agree** | |
| N4 own status icon | rejected: **agree** | |
| N5 alpha-0 windows | verified | ScreenCapture.swift:122 |
| N6 sharingType | verified | It is no longer set on overlays. |
| N7 point/pixel types | verified | `PixelRect` is an integer type with `pixelRect`/`points`/`clamped`/`flippedY`. It has an epsilon and is covered by tests. |
| N8 highlighter floor | verified | The highlighter uses the style's opacity. |
| N9 changeCount | verified | `copyToClipboard` returns the result of `writeObjects`. |
| N10 PNG DPI | verified | `savePNG` writes the DPI from the scale. |
| Plan #2 | still partial | See N-R2-1. The shadow geometry is unverified. |
| Plan #5 docs | verified | The string is gone from `plans/`. It remains only in old review files. |
| Missing ShareX features | deferred: **agree** | Out of scope for this round. |

Nothing regressed. The only item not fully fixed is S13, in canvas mode.

## (a) Live window capture (`ScreenCapture.captureWindow`, :92-107)
Correct:
- The window is looked up by `windowID`, with `.windowGone` when it is missing.
- `desktopIndependentWindow` captures covered windows whole.
- The screen is chosen by largest overlap, and the scale comes from `filter.pointPixelScale`.
- The work stays on MainActor.
- A countdown runs before the capture.

**N-R2-1 should-fix [UNVERIFIED]: the shadow and the output size.**
- `contentRect` is a property of the *filter* and cannot know about `config.ignoreShadowsSingleWindow`. The comment says it "covers the shadow when kept", and I doubt that.
- If `contentRect` is the bare window frame and the shadow is kept, SCK either scales window plus shadow into that size (the window shrinks a little and the image is soft) or clips the shadow.
- Test this on a Mac by comparing `image.width` with `w.frame.width * scale` for shadow on and shadow off.
- Safe fallback if they match, meaning no shadow room was added:
```swift
// shadow off: exact pixels, no resampling
config.ignoreShadowsSingleWindow = true
config.width = Int((w.frame.width * scale).rounded()); config.height = Int((w.frame.height * scale).rounded())
// and keep the synthetic DecorationLayout shadow (deliver(shadowed: false)) until the real-shadow size is proven
```
- Related nit: when a border is on and the real shadow is kept, `decorate` draws the border around the shadow's transparent padding rather than around the window.

**Nit:** a `.windowGone` error (the window closed between click and capture) only beeps. Show the same alert or notification used for the other errors.

**Nit:** `showsCursor` with a single-window filter may draw the cursor even when it is outside the window [UNVERIFIED]. Set `showsCursor = false` for window captures, as ShareX does by default.

## (b) Core Image blur/pixelate (`Renderer.effectPatch`, :102-124)
Correct:
- `flippedY` gives a CI rect with a bottom-left origin.
- The chain is crop → `clampedToExtent` → filter → `createCGImage(from: ciRect, format: .RGBA8, colorSpace: frame.colorSpace)`, so edges don't fade to transparent.
- The patch is pixel-aligned at the renderer scale.
- `CIPixellate` is centred on `(minX, maxY)`, so the grid is anchored at the top-left as in ShareX.
- The `CIContext` is reused.
- The redaction is baked into the export because `flatten` calls `renderer.draw`.

**N-R2-2 should-fix (redaction strength):**
- `sigma = strength*scale/2`. The old three-pass box blur of radius r is about a Gaussian with σ≈r, so this blurs half as much as the reference.
- At the minimum strength, small text can stay readable.
- Fix:
```swift
let sigma = max(4, strength * scale)   // match 3x box(r) ≈ σ=r; floor so small strengths still redact
```

**N-R2-3 should-fix (cache thrash):**
- The cache holds 8 entries and calls `removeAll` when full.
- With 9 or more blur/pixelate marks, every `draw` clears the cache and recomputes every patch.
- Moving a blur with the Select tool also adds a new entry per mouse-drag event, because `liveEffectID` is only set for new shapes and handle resizes.
- Fix: key the cache by annotation id and overwrite in place.
```swift
private var effectCache: [Int: (key: EffectKey, image: CGImage)] = [:]
// lookup: if let c = effectCache[a.id], c.key == key { return c.image }
// store:  effectCache[a.id] = (key, img)   // drop ids no longer in doc on draw
```
In addition, set `renderer.liveEffectID = a.id` in the `.select` move branch of `editingMouseDown` when `a.kind.isEffect`.

## (c) Hidden main menu (`Main.swift`)
- `app.mainMenu = editMenuBar()` runs before `run()`.
- Undo `undo:` ⌘Z, Redo `redo:` ⇧⌘Z, and Cut/Copy/Paste/Select All go to the first responder.
- `EditorView` implements `@objc undo(_:)`, `redo(_:)` and `copy(_:)`. `copy` only finishes in the editing phase.
- The text field editor gets the standard actions.

I expect this works. For an LSUIElement app, `NSApp.mainMenu` still handles key equivalents while the app is active, even though no menu bar shows [UNVERIFIED].

To check on the Mac, test all three while the text field is open:
- ⌘Z should undo typing, not the document.
- ⌘V should paste.
- ⌘C on the canvas should copy and close.

**Nit:** `NSApp.activate()` is asynchronous. A keystroke sent right after the hotkey can still go to the previous app.

## New findings
- **N-R2-1 should-fix [UNVERIFIED]:** window shadow and output size. See (a).
- **N-R2-2 should-fix:** blur sigma is half the reference. See (b).
- **N-R2-3 should-fix:** effect cache thrash with more than 8 marks, and when moving an effect. See (b).
- **N-R2-4 should-fix: the toolbar is clipped in canvas mode.**
  - The problem:
    - The canvas window is sized to the image, and the toolbar sits inside it.
    - For a small window (under about 500 pt) the style row overflows even in vertical mode, so Done, Cancel and Trash fall outside the window.
    - Enter and Esc still work.
  - Fix in `OverlayController.init(canvas:)`:
```swift
let minW = max(size.width, 560), minH = max(size.height, 240)   // room for the two-row toolbar
// centre the image inside the larger content rect; margin stays transparent/grey
```
  - Alternatively, put the toolbar in an `NSTitlebarAccessoryViewController` for canvas windows.
- **N-R2-5 should-fix [UNVERIFIED, needs a Mac compile]: Swift 6 concurrency.**
  - `DispatchQueue.main.async { for s in closing … }` captures `[Surface]`, which holds NSWindow and NSView, in a `@Sendable` closure.
  - With `SWIFT_STRICT_CONCURRENCY: complete` and Swift 6 mode, this may fail with "capture of non-sendable type".
  - Use `Task { @MainActor in for s in closing { s.window.contentView = nil } }`, which keeps it on MainActor and needs no Sendable.
- **Nit:** the canvas is drawn with interpolation `.none`. When `viewScale` differs from the backing scale (the image was scaled down to fit), it aliases. Use `.medium` in that case.
- **Nit:** `pickIndex(of:)` looks the rect up again with `firstIndex(of:)`. Pass the index from `pickTarget` instead of the rect.
- **Nit:** the comment on the canvas `viewScale` says "points per pixel", but the value is pixels per point.
- **Nit:** `xcodegen` fails until `Local.xcconfig` exists [UNVERIFIED that XcodeGen validates configFiles]. A committed `Base.xcconfig` with `#include? "Local.xcconfig"` avoids this.

## Remaining blockers
None. All four round 1 blockers are fixed in code. N-R2-1 and N-R2-5 can only be settled with a build on the Mac.
