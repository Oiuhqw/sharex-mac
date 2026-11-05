> Historical review of an earlier revision. See [the review index](README.md) for current evidence and validation status.

# Validation (macOS developer, round 3): source traced end to end before the Mac E2E run

**Summary: 36 features checked. 29 WORKS, 4 BUG, 3 UNVERIFIABLE-ON-LINUX. No blockers.** All four bugs are small, and each has a fix below.
WORKS means I traced the logic from trigger to output and found it correct. It still has to be run on a Mac.

**Results run this round**
- `swift test --package-path Packages/ShareXCore`: 39 tests, 0 failures, exit 0.
- `swiftc -parse` on every `App/Sources/*.swift`: no errors. This checks syntax only. AppKit and ScreenCaptureKit code is not typechecked on Linux.

**Common path:** every capture runs through the same code.
- Triggers:
  - The status menu `Main.swift:62-66` calls `captureItem` `:114-118`, waits 0.15 s, then calls `CaptureCoordinator.capture`.
  - Hotkeys `Hotkeys.swift:17-28` cover all 8 styles. Five have defaults (⌃⇧1–5). Active Window, Monitor… and Last Region are unbound but can be recorded in `SettingsView.swift:43-45`.
- `capture` → `run` `CaptureCoordinator.swift:13-30`: busy guard → permission check → countdown → style switch `:39-53` → `ScreenCapture.freeze` `ScreenCapture.swift:69-88`, which excludes our own app's windows.
- One of three branches follows:
  - direct `deliver` `CC:66-73`;
  - `OverlayController(frozen:)` `OC:37-69`;
  - `openCanvas` `CC:102-109`.
- Output: `deliver` `CC:135-142` → `Export.decorate` → `copyToClipboard` → optional save, last region and sound.

| Feature | Status | Evidence file:line | Bug/fix |
|---|---|---|---|
| **Fullscreen** | WORKS | One screen: `CC:50-51` builds a full-screen preset. With the editor on it goes to the overlay with `initialCrop` (`OC:59`, `EditorView:64`); with it off, `CC:66-72` flattens and delivers. Several screens: `CC:57-63` → `stitch` `CC:145-156` places each display at its global position at the highest scale → canvas or deliver. | |
| **Active Monitor** | WORKS | `CC:45-46` takes the screen under the mouse (`CC:32-33`, read after the countdown), freezes only that screen and sets a preset. From there the path is the same as fullscreen. | |
| **Monitor picker** | BUG (minor) | `.pickMonitor` (`Capture.swift:25`) → `OC:49` makes the whole screen the pick target → click → `EditorView:236-237` `enterEditing`. | The "Open editor for fixed areas" setting (`openEditor`) is ignored: this style always opens the editor, while Fullscreen, Active Monitor, Active Window and Window picker all respect it. Fix: give `EditorView` an `openEditor` flag and, in the `.pickMonitor` branch, call `enterEditing(crop: r)` then `finish()` when it is false. Or treat Monitor… like Window… with an outcome such as `.pickedMonitor(displayID)`, and let the coordinator flatten and deliver. |
| **Active Window** | WORKS (SCK runtime UNVERIFIABLE) | `CC:40-44` runs after the countdown. `ScreenCapture.activeWindow` `SC:135-138` takes the frontmost app's first layer-0 window → `editOrDeliver` `CC:96-100` → `captureWindow` `SC:93-108` (desktop-independent filter, no shadow, frame × `pointPixelScale`) → canvas or deliver. If ShareX itself is frontmost, our windows are excluded, so you get a beep (`CC:42`). | |
| **Window picker** | WORKS | `OC:41,50-55` turns `windows()` into pick rects plus a parallel `pickWindows` list → hover highlight `EV:mouseMoved` → click `EV:235` gives the index → `OC:165-168` returns `.pickedWindow` → `CC:84-90` captures live and stays busy → canvas or deliver. If the window is gone, an alert shows (`CC:124-130`). | |
| **Region** | WORKS | `.rectangle` → drag `EV:166,231` (a click with no drag snaps to the window under the cursor, using `pickRects`) → `enterEditing` → Enter → `OC:170-174` `flatten` → `deliver` with `LastRegion` (`CC:75,82-83`). | |
| **Last region** | WORKS | `CC:28-29` falls back to Region when nothing is stored or the display is gone. `CC:47-49` uses only the stored display and the stored rect as the preset. Editor off: `CC:66-72` flattens and delivers, and the region is remembered again. Editor on: the overlay opens with the crop, and `remember` is true (`CC:75`). It stores the final crop rect (bounding box only, which matches ShareX). | |
| **Freehand / lasso** | WORKS | `.lasso` → `EV:167` builds the point list → mouseUp `EV:~229` (at least 3 points, then the bounding box becomes the crop) → editor dims outside the lasso (`EV:~392`) → `Export.flatten` `Export.swift:16-18` clips to the lasso, so pixels outside are transparent. | |
| **Delay timer** | WORKS | The setting is read in `CC:18,25` → `Countdown.run` `Countdown.swift:5-29`, which counts down, then `orderOut` and an 80 ms wait before the freeze. Set from the menu (`Main:81-89,120`) or Settings (`SettingsView:31`). | Nit: Esc can't cancel during the countdown. |
| **Show cursor** | WORKS | `CC:55` `freeze(showCursor:)` → `SC:61` `showsCursor`. Applies to every display-frame style. | By design, window styles force it off (`SC:98`, as in ShareX). Document this in the README so the E2E tester doesn't report it. |
| **Magnifier / crosshair** | WORKS | `OC:60` passes the setting → `EV:387`, which draws only in Region and Freehand while selecting → `drawCrosshair`/`drawMagnifier` (15×15 source pixels at 8×, edge-safe, with pixel coordinates). | |
| **Window border** | WORKS | Menu toggle `Main:92,123-124` (0↔2) or Settings stepper (`SV:37`) → `decorate` `Export:26-40` fills a frame of border × scale, then clears and redraws the image. Applies to every style. | Nit: `borderColor` has no UI (always black). |
| **Drop shadow** | WORKS | `Main:93`, `SV:38` → `decorate` `Export:31-38` uses `DecorationLayout` (points × scale, `Capture.swift:76-83`). Window captures now always drop the system shadow and get the drawn one (`SC:99`). | Nit: the shadow is drawn from a rectangle, so a window's transparent rounded corners show the rectangular shadow edge. Also, the comment at `Capture.swift:50` is stale ("Window styles keep the system shadow"). |
| Rectangle | WORKS | `EV:196-200` adds the shape, `extendShape` follows the mouse (Shift makes a square), mouseUp calls `endDrag` (marks under 3 pt are discarded) → `Renderer:115-116` strokes or fills. | |
| Ellipse | WORKS | Same path → `Renderer:117-118`. | |
| Line | WORKS | → `Renderer:119-120`. Shift snaps to 45° (`EditorDocument:261-263`). Resizing moves the nearer endpoint. | |
| Arrow | WORKS | → `Renderer:121-125`. The head is max(10, 4×width) and filled. | |
| Highlight | WORKS | → `Renderer:126-129`. Multiply blend at the style's opacity (default yellow at 0.4). | |
| Blur | WORKS | → `Renderer:135-136` `effectPatch` `:180-200`, using CI Gaussian σ = max(4, strength × scale) on the frozen frame clamped to the mark → export (`flatten` → `draw`), so the redaction is in the pixels. | |
| Pixelate | WORKS | Same path with `CIPixellate`, scale ≥ 2, grid anchored at the top-left. | |
| Spotlight | WORKS | `Renderer:137-142` dims everything outside the ellipse (even-odd fill) by strength/100, capped at 0.9. Slider range 2–90. | |
| Pen | WORKS | `addShape` starts `points` with the first point (`Annotation:75`) → `extendShape` appends (`ED:255`) → `Renderer:130-134`. Fewer than 2 points is discarded. | |
| Text (plain) | WORKS | `EV:192-195` adds the mark and calls `beginTextEditing` `EV:~334`, an `NSTextField` → Return, Esc or losing focus calls `commitText` → `setText` (empty text deletes the mark) → `drawText` `Renderer:156-167` in a flipped NSGraphicsContext. Clicking an existing text mark re-edits it. | See the undo bug below. |
| Text (background) | WORKS | Fill is enabled for text (`Toolbar:T+107`) → `Renderer:162-165` draws a white box at 0.9 behind the text. | |
| Step markers | WORKS | `.step` is never treated as too small (`Annotation:~150`) → `Renderer:145-152` draws a circle and its number. `stepNumber` renumbers after a delete (`ED:222-224`). The width slider sets `fontSize` (`Toolbar:T+100,T+120`). | |
| **Crop** | BUG (minor) | `EV:189-191` starts the crop drag → `EV:215` → `endDrag` records it in undo history. | `EV:215` passes the result of `Geometry.clamp` straight into `setCropLive`. `clamp` returns nil for a rect under 1 pt (`Geometry.swift:38-41`). A tiny drag with the crop tool therefore sets crop to nil; the editor then draws as if nothing were cropped, but Enter and ✓ do nothing (`EV:135` `guard let crop`). Fix: `case .cropNew(let s): if let r = Geometry.clamp(Geometry.rect(from: s, to: p), to: bounds0) { doc.setCropLive(r) }`. |
| Select / move / resize / delete | WORKS | Hit test is topmost first; outlines are hollow (`Annotation:103-118`) → move (`EV:182-185`), handle resize (`EV:176-179`), arrow-key nudge of 1 or 10 (`EV:~320`), Delete/⌫ (`EV:304`), toolbar trash, and right-click deletes the mark under the cursor (`EV:249-257`). | |
| **Per-tool color/width/fill/opacity** | BUG | Toolbar `T+113-124` → `changeStyle` → `ED:285-291` updates the selected mark and `doc.styles` for this session only. | The styles are never saved. `settings.toolStyles` is read in `OC:59,100`, but no code writes it (grep shows no writer), so every capture starts with default styles. ShareX remembers them. Fix: in `OverlayController.close`, or in `CC` on `.finished`/`.cancelled`, save the styles: pass `onStyles: ([ShapeKind: ShapeStyle]) -> Void` into `OverlayController`, call `onStyles(s.view.doc.styles)` in `editorDidFinish`/`editorDidCancel`, and in `CC` do `settings.update { $0.toolStyles = styles }`. |
| Tool hotkeys | WORKS | `EV:317` `Tool.forKey` (`Annotation:26-32`: V, C, R, E, L, A, H, B, P, S, F, T, I), active only while editing. While the text field is focused it has first responder, so typing doesn't switch tools. Tooltips match. | |
| **Undo/redo** | BUG (minor) | Hidden menu ⌘Z / ⇧⌘Z (`Main:29-32`) → `EV:114-115`, plus toolbar buttons. Snapshot stack (`ED:12-40`, 200 deep). Each drag is one step; crop, style and delete are undoable. | Text takes two undos. `EV:194` records the empty text mark as an add (`beginDrag`/`addShape`/`endDrag`), and then `setText` records again. One ⌘Z leaves an invisible empty text mark that can still be selected. Fix: in `EV:194` drop `beginDrag`/`endDrag` and call `doc.addShape` alone, so that only `setText` records. Store `before` in `beginTextEditing` for new marks, or have `setText` record `before` without the mark. |
| Enter / double-click finalizing | WORKS | Return or keypad Enter (`EV:303`), ✓ button, ⌘C (`EV:116`, via the menu), or a double-click on empty space (`EV:162`) → `finish` `EV:133-137` → `OC:170-174` → `flatten` at full frame resolution → `deliver`. | |
| Clipboard: one item, PNG + TIFF | WORKS | `Export:48-58`: `clearContents`, then one `NSPasteboardItem` with `.png` and `.tiff`, then `writeObjects`. The rep size is pixels/scale, so it pastes at on-screen size. If the write fails you get a beep. | |
| Esc cancels, clipboard untouched | WORKS | `EV:302` (or the ✗ button, a right-click with no marks, or the canvas close button `OC:179`) → `close(.cancelled)` `OC:135-145` → `endSession`. No pasteboard call on this path. In the text field, the first Esc commits the text and the second cancels. | |
| Hidden main menu key equivalents | UNVERIFIABLE-ON-LINUX | `Main:13,21-40`. Whether an LSUIElement app with a hidden main menu handles ⌘Z/⌘C/⌘V depends on AppKit at runtime. | On the Mac, test ⌘Z on the canvas, ⌘Z inside the text field, ⌘V in Settings, and ⌘C to finish. |
| Live window capture output | UNVERIFIABLE-ON-LINUX | `SC:93-108`: exact size, transparent corners, covered windows captured whole. | On the Mac, check that the image is frame × scale and not blurry. |
| Countdown HUD excluded from the frame | UNVERIFIABLE-ON-LINUX | `Countdown:18,24-26` sets `sharingType = .none`, then `orderOut` and an 80 ms wait. Our own app is also excluded in `SC:71,76`. | |

## Status of the r2 items
| r2 item | Status | Evidence |
|---|---|---|
| N-R2-1 shadow/size | fixed | `SC:99-103` always sets `ignoreShadowsSingleWindow`, sizes the image from the frame, and uses the drawn shadow. |
| N-R2-2 blur σ | fixed | `Renderer:189-192` uses σ = max(4, strength × scale). |
| N-R2-3 cache thrash | fixed | The cache is keyed by mark id, stale ids are pruned (`Renderer:87,103-104,184,198`), and `liveEffectID` is also set on move (`EV:185`). |
| N-R2-4 canvas toolbar clipped | fixed | `OC:84-90` sets a minimum of 760×420 pt. |
| N-R2-5 Swift 6 capture | fixed | `OC:142` uses `Task { @MainActor in … }`. |
| windowGone silent | fixed | `CC:124-130` shows an alert. |
| `showsCursor` for window captures | fixed | `SC:98` |
| canvas interpolation | fixed | `smoothFrame` (`OC:98`, `Renderer:98,136`) |
| `pickIndex` by rect | fixed | `EV:235` and `OC:165` pass an index. |
| `viewScale` comment | fixed | `OC:86` |
| border around shadow padding | fixed | Same as N-R2-1. |
| xcodegen without Local.xcconfig | fixed | `Base.xcconfig` has `#include? "Local.xcconfig"`, and `project.yml:37-38` uses it. |
| `NSApp.activate` async | not fixed (nit) | Accepted. |
