# ShareX macOS — Head of Eng validation (static review + core tests)

Scope: `App/Sources/*` (14 files), `Packages/ShareXCore` (6 sources, 3 test files), checked against `PLAN.md` and `plans/head-of-eng.md` (M0–M8). **Everything below about the app is static wiring only. Nothing was built or run on macOS.** That includes ScreenCaptureKit, TCC, overlay input, Retina crops and pasteboard consumers. Only the `ShareXCore` tests were executed, on Linux.

## Verdict
The code fits the plan well. Every HoE M0–M5 item is implemented and statically wired from a menu item or hotkey through `CaptureCoordinator` → `ScreenCapture` (SCK) → `OverlayController`/`EditorView` → `Export.flatten`/`decorate` → `Export.copyToClipboard` (`NSPasteboard`, one item with PNG and TIFF). M6 (freehand), hotkeys, menu bar, annotation and save-to-file are also present. I found no TODO/FIXME/stub paths. The core suite passes (39/39). There are three real problems: (1) the tested `Bitmap` blur/pixelate code is **not used by the app**, because the app redacts with CoreImage in `Renderer.swift`, which leaves the "blur can't be reversed" guarantee untested; (2) `AppSettings.toolStyles` is read but **never written back**, so tool style changes don't persist across captures; (3) `borderColor` has no UI. Two PLAN items are missing: M4 "re-edit last capture" and M5 scrolling capture. Mac behavior is unverified until the founder runs the checklist.

## M0–M5 matrix (HoE plan numbering)
| Item | Status | Evidence |
|---|---|---|
| M0 Screen Recording permission | Implemented & wired | `Main.swift:56` requests at launch; `CaptureCoordinator.swift:24` gates every capture; `Permissions.showDeniedAlert` offers Open Settings, Quit & Reopen or Cancel; SCK `.userDeclined` → `.noPermission` (`ScreenCapture.swift:49-51`). Unverified: TCC caching after re-sign. |
| M1 Fullscreen | Implemented & wired | Single display: preset full rect (`CaptureCoordinator.swift:50`). Multi-display: `stitch()` at max scale (`:57-63,145-156`). |
| M1 Active monitor | Implemented & wired | Uses the screen under the mouse (`CaptureCoordinator.swift:33,45-46`). |
| M2 CaptureIntent before capture | Implemented & wired | `CaptureRequest(style, options)` is built from settings before the delay or freeze (`:18`). Options come from the menu's "Before capture" submenu (`Main.swift:77-96`) and Settings. This is a menu, not a dedicated panel; that is acceptable. |
| M3 Region picker: rubber band | Implemented & wired | `EditorView` `.rectangle` mode; selection becomes the crop. |
| M3 Crosshair / magnifier | Implemented & wired | `EditorView.swift:268` (crosshair cursor), `:387` draws crosshair and magnifier when `showMagnifier` is on (rectangle and lasso only). |
| M3 Esc cancels | Implemented & wired | `EditorView.swift:302` (keyCode 53) → `editorDidCancel` → `.cancelled`, so the clipboard is untouched. In text editing, Esc commits the text instead (`:354`). |
| M4 Window capture | Implemented & wired | Picker: `ScreenCapture.windows()` (CGWindowList) gives the pick rects; the click is captured live with `SCContentFilter(desktopIndependentWindow:)`. Active Window is also there. Partially off-screen behavior is unverified. |
| M5 Delay timer + countdown | Implemented & wired | `Countdown.run` with `sharingType = .none`, closed 80 ms before the freeze. Choices: 0/1/2/3/5/10 s. |
| M5 Cursor on/off | Implemented & wired | `SCStreamConfiguration.showsCursor` (`ScreenCapture.swift:61`). Window captures always omit the cursor (deliberate, documented at `:92`). |
| M5 Border / shadow | Partial | `Export.decorate` and `DecorationLayout` are tested. Border width can be set in the menu (0↔2) and in a Settings stepper. **`borderColor` has no UI** (always black). Comment `Capture.swift` "Window styles keep the system shadow" contradicts `ignoreShadowsSingleWindow = true` (`ScreenCapture.swift:99`); the code draws its own shadow. |
| Clipboard | Implemented & wired | `Export.copyToClipboard`: `clearContents`, then one `NSPasteboardItem` with PNG and TIFF, point size = px/scale. A failure beeps. |

### M6–M8 / PLAN extras
| Item | Status |
|---|---|
| Freehand/lasso (M6) | Implemented. Lasso clip in `Export.flatten` makes the outside transparent. |
| Scrolling capture (M7 / PLAN M5) | **Missing.** No code. |
| Hotkeys | Implemented. KeyboardShortcuts package; ⌃⇧1–5 defaults plus 3 unbound; a Settings recorder tab. |
| Menu-bar mode | Implemented (`LSUIElement`, `NSStatusItem`, menu rebuilt on each open). |
| Annotation editor | Implemented: 13 tools, colors, width, opacity, fill, strength, undo/redo, delete, Enter/Esc (`ToolbarView.swift`, `Renderer.swift`, core `EditorDocument`). |
| Save to file | Implemented. Optional auto-save to a folder (`Export.savePNG`); no `NSSavePanel`. |
| Monitor picker, Last region | Implemented (`.pickMonitor`; `LastRegion.resolve` falls back to Region). |
| Re-edit last capture window (PLAN M4) | **Missing.** |
| No upload UI | Confirmed. No network code. |

## Menu → clipboard wiring map
```
NSStatusItem menu (Main.swift:60) ─ captureItem ─┐
Hotkeys.register (Hotkeys.swift:24) ─────────────┼─> CaptureCoordinator.capture(style)  [busy guard]
                                                 └─ run(): Permissions → LastRegion.resolve → Countdown.run
   ├─ activeWindow → ScreenCapture.activeWindow → captureWindow (SCK) → editOrDeliver
   ├─ else ScreenCapture.freeze(targets, showCursor) (SCK SCScreenshotManager, own app excluded)
   │    ├─ fullscreen multi-display → stitch → [openEditor ? canvas editor : deliver]
   │    ├─ preset (activeMonitor/lastRegion/1-display fullscreen) && !openEditor → Export.flatten → deliver
   │    └─ OverlayController(frozen, mode) → EditorView
   │          ├─ .finished → Export.flatten(renderer, doc, crop, lasso) → deliver
   │          ├─ .pickedWindow → captureWindow → editOrDeliver
   │          └─ .cancelled → endSession (no clipboard write)
   └─ deliver(): Export.decorate(border/shadow) → Export.copyToClipboard (NSPasteboard PNG+TIFF)
                 → [saveToFile ? savePNG] → lastRegion update → [playSound]
Settings window (SettingsView) ↔ SettingsStore.update → UserDefaults "settings.v1"
```
Every menu item has a target and action; none are no-ops. "Border" is the one tag `-1` toggle and is handled specially (`Main.swift:123-125`).

## Stubs / TODOs / dead paths / unread settings
- **Grep** (TODO, FIXME, stub, fatalError, notImplemented, unimplemented, #warning, placeholder) over `App/` and the Core sources: only two `fatalError("unused")` in `required init?(coder:)` marked `@available(*, unavailable)` (`EditorView.swift:72`, `ToolbarView.swift:79`). This is standard and harmless.
- **Settings read map:**
  | Field | Written by | Read in capture path |
  |---|---|---|
  | options.delaySeconds | menu, Settings | `Countdown.run` ✔ |
  | options.showCursor | menu, Settings | `freeze` ✔ |
  | options.showMagnifier | menu, Settings | `EditorView` ✔ |
  | options.borderWidth | menu, Settings | `decorate` ✔ |
  | options.borderColor | **nothing** (no UI) | `decorate` (always black) ⚠ |
  | options.shadow | menu, Settings | `decorate` ✔ |
  | options.openEditor | menu, Settings | coordinator ✔ |
  | toolStyles | **never written by the app** | `EditorDocument` init ⚠ style tweaks are lost after each capture |
  | lastRegion | `deliver` | `run` ✔ |
  | saveToFile / saveFolder | Settings | `deliver` / `savePNG` ✔ |
  | playSound | Settings | `deliver` ✔ |
- **Dead / unshipped code:**
  - `ShareXCore/Bitmap.swift` (pixelate/blur) is not referenced anywhere in `App/`. The app uses CoreImage (`Renderer.effectPatch`). Its 6 tests cover code that never ships.
  - `Geometry.frameIndex`, `Geometry.polygon(_:contains:)` and `Geometry.displayTopLeftToCocoa` have no App callers (tests only).
  - `DecorationLayout.borderRect` is unused.
  - `EditorView.styles` getter (`:85`) has no caller. It looks like the intended hook for persisting `toolStyles`, which was never connected.

## Test coverage + swift test transcript
Command (as specified): `export LD_LIBRARY_PATH=/tmp/swiftlibs PATH=/tmp/swift-6.0.3-RELEASE-ubuntu22.04/usr/bin:$PATH; swift test --package-path /workspace/sharex-mac/Packages/ShareXCore`.
Result: **XCTest: 39 tests, 0 failures. Exit 0.** Suites: GeometryTests 13, Editor tests 15, Bitmap 6, SettingsTests 5. swift-testing: 0 tests (none defined).

Judgment: the tests are meaningful, not smoke-only, for **Geometry** (drag directions, multi-display coordinate flips including a secondary display above-left, pixel snap and clamp, shared-edge ownership, handle resize and flip, decoration layout) and for **EditorDocument** (undo/redo/limit, click-without-drag discard, step renumbering, move as one undo step, resize, shift-constrain, hit testing, text removal, style-default propagation, crop undo, tool keys). **Settings** coverage is good: round-trip, per-key corrupt fallback, LastRegion resolve and fallback, filename, style→selection mode. Weak spots:
- The Bitmap tests verify an implementation the app doesn't use. The shipped CoreImage redaction (the PLAN's "blur can't be reversed" claim) has **zero** automated coverage.
- Everything in `App/` has no tests: coordinator branching, `decorate` pixels, clipboard. The Linux box can't run them, so this coverage gap is expected.
- No test asserts that `CaptureStyle` preset/remember logic matches the coordinator, because that logic lives in App.

## Gaps vs PLAN.md / HoE plan
1. Scrolling capture: absent (PLAN M5 / HoE M7; time-boxed, acceptable to defer, but say so explicitly).
2. "Re-edit last capture" editor window (PLAN M4): absent.
3. `borderColor` has no UI. The PLAN asks for per-tool settings that persist; `toolStyles` don't persist.
4. PLAN layout says CaptureCore/CaptureKit/CaptureUI/Annotate modules. The actual shape is one App target plus one Core package. This is fine, but the PLAN should be updated to match.
5. CaptureIntent is a menu submenu, not the panel the HoE plan proposed. That is acceptable; note it in the checklist.
6. The founder checklist still has to verify all of these on a Mac: TCC grant/deny, Retina/mixed-DPI crops, overlay focus over full-screen apps, PNG+TIFF paste into Preview/Notes/Slack, cursor visibility, and blur irreversibility.

## Recommended fixes (ordered)
1. Persist tool styles: on finish or cancel, write `view.styles` back with `settings.update { $0.toolStyles = … }` (OverlayController close path).
2. Pick one redaction implementation. Either have `Renderer` use `ShareXCore.Bitmap` for blur/pixelate, or delete `Bitmap` and its tests and add a Mac-only XCTest that checks the CoreImage patch differs from the source and can't be inverted. Without this, the "blur irreversible" claim is backed only by the manual checklist.
3. Add a border colour control (palette picker in Settings), or remove `borderColor` from `CaptureOptions`.
4. Fix the misleading comment on `CaptureOptions.shadow` (window shadow is dropped and redrawn).
5. Delete the unused `Geometry.frameIndex`, `polygon(_:contains:)`, `displayTopLeftToCocoa` and `DecorationLayout.borderRect`, or wire them in.
6. Decide whether re-edit-last-capture and scrolling capture are in v1, and update PLAN.md to match.
7. Founder runs the HoE §4 checklist on a Mac. Also add a check that Esc during text entry commits rather than cancels, and a check for the 0.15 s menu-close delay before the freeze.
