> Historical review of an earlier revision. See [the review index](README.md) for current evidence and validation status.

# ShareX for macOS: end-to-end and formal verification review

Date: 2026-11-03. Commit verified: `HEAD` of `main`. Green run: https://github.com/Oiuhqw/sharex-mac/actions/runs/41577460497

## Summary
- **E2E**: real app on a GitHub `macos-15` runner (macOS 15.8.2, Xcode 16), driven by `ShareX --e2e`. **47 scenarios: 46 pass, 1 unverifiable** (multi-display: the runner has one screen). Results and PNGs: `reviews/e2e/`.
- **TLA+** (`formal/Capture.tla`, TLC): found one real bug, alert focus not restored. With the fix, TLC checks 95 distinct states and finds no errors, with the editor both on and off.
- **Core property tests**: 59 Linux tests pass (`swift test` in `Packages/ShareXCore`), including the new `PropertyTests.swift`.
- **Bugs fixed**: 1 product bug (below) and several test-harness bugs. No product regressions.

## Frame source (read this first)
- ScreenCaptureKit **was granted** through the TCC.db insert and works (`frameSource` is not `fixture`).
- **Window captures are real SCK.** This covers Window picker and Active Window, in both modes (`auto-windowPicker.png` shows the real "E2E Pattern" window).
- **Display captures use a synthetic checkerboard.** On the hosted runner, SCK display frames show only a black desktop plus the menu bar and Dock; other apps' windows are not composited (`runner-desktop.png`, taken with `screencapture`, looks the same). A uniform frame would make blur, pixelate, highlighter and spotlight unverifiable, so the driver detects the uniform frame and swaps in a synthetic frame for display captures only (`ScreenCapture.e2eDisplayFixture`). Every scenario that uses a display frame is labelled `sck-window+fixture-display`:
  - Fullscreen, Active Monitor, Monitor picker, Region, Last Region, Freehand
  - all the tools
- Run 41576827048, before the swap, ran those same paths on the **real black SCK frame**. Dimensions, clipboard and file checks all passed. Only the pixel-change checks on uniform black failed, as expected.

- **Caveat (macOS Developer review):** because display captures are replaced by the fixture, the display *size* checks in the green run (41577460497) are circular: the fixture is generated at the expected size, so a size match there proves nothing about real display capture (`ScreenCapture.swift:75-80`). Real display sizing through SCK was proven separately in run [41576827048](https://github.com/Oiuhqw/sharex-mac/actions/runs/41576827048). Window captures in the green run are real SCK.

## Feature inventory (all exercised)
| Area | Features |
|---|---|
| Menu bar | Fullscreen, Active Monitor, Monitor…, Active Window, Window…, Region, Last Region, Freehand, Before capture ▸ (Delay, Show cursor, Magnifier, Border, Drop shadow, Open editor for fixed areas), Settings…, Quit |
| Overlay | select, re-select, Esc, right-click cancel, double-click finish, Return, ⌘C, Edit ▸ Copy, crop tool |
| Tools | rectangle, ellipse, line, arrow, highlighter, blur, pixelate, spotlight, pen, text, step; undo/redo; per-tool style persistence |
| Output | clipboard (PNG+TIFF), save to folder with collision naming, save off, border, drop shadow, DPI metadata, countdown delay |
| Other | global hotkey ⌃⇧1, settings persistence across relaunch, previous-app reactivation, re-entrancy guard |

## Clipboard matrix
Every capture checks the following (`checkClipboard`):
- exactly **1 pasteboard item** with `public.png` + `public.tiff`
- PNG and TIFF are the expected size and **equal pixel for pixel**
- the newly saved file **equals the clipboard pixel for pixel**, with the right DPI and the `ShareX_yyyy-MM-dd_HH-mm-ss[-n].png` name
- changeCount advanced and the sentinel string is gone, so the clipboard was **replaced, not appended**

| Path | Mode | Size px | Feature check | Result |
|---|---|---|---|---|
| Region baseline | editor | 400×300 | – | ✅ |
| Rectangle / Ellipse | editor | 400×300 | red edge pixel | ✅ ✅ |
| Line / Arrow / Pen | editor | 400×300 | red midpoint | ✅ ✅ ✅ |
| Highlighter | editor | 400×300 | yellow tint vs baseline | ✅ |
| Blur | editor | 400×300 | 100% of inner box changed, 0% outside | ✅ |
| Pixelate | editor | 400×300 | 25% of inner box changed, 0% outside (see note) | ✅ |
| Spotlight | editor | 400×300 | outside darkened, inside unchanged | ✅ |
| Text / Step | editor | 400×300 | red pixel fraction 0.15 / 0.83 | ✅ ✅ |
| **Combined** blue/8 rect + blur + arrow + undo/redo + crop | editor | 300×200 | blue rect, undo counts [3,2,3,3], style persisted | ✅ |
| Finish via ⌘C / Edit▸Copy / double-click / Return | editor | 400×300 | – | ✅ ✅ ✅ ✅ |
| Replace-not-append (2 captures back to back) | editor | 100×50 | 1 item | ✅ |
| Fullscreen / Active Monitor / Monitor picker | **auto (editor off)** | 1024×768 | – | ✅ ✅ ✅ |
| Last Region | auto | 100×50 | – | ✅ |
| Window picker / Active Window (real SCK) | auto | 944×676 | – | ✅ ✅ |
| Freehand lasso | auto | 400×300 | alpha 0 outside the shape, 1 inside | ✅ |
| Fullscreen / Active Monitor / Last Region | **editor on** | 1024×768 / 1024×768 / 400×300 | drawn rect present | ✅ ✅ ✅ |
| Monitor picker / Window picker / Active Window (canvas editor) | editor on | 1024×768 / 944×676 / 944×676 | – | ✅ ✅ ✅ |
| Countdown completes | auto | 1024×768 | – | ✅ |
| Border 3pt / Drop shadow | auto | 1030×774 / 1088×832 | border pixel / padded size | ✅ ✅ |
| Retina 2x pipeline (synthetic 2x frame) | editor | 600×400 (300×200 pt) | 144 DPI, red pixel | ✅ |
| Save off | – | – | clipboard only, no file | ✅ |
| Save naming collision | – | – | `-3`, `-4` suffixes | ✅ |
| **Esc / cancel leaves clipboard unchanged** | countdown Esc, overlay Esc (selecting and editing), right-click, canvas editor close, re-entrancy | – | clipboard unchanged, busy=false, no overlay | ✅ ×6 |
| Multi-display | – | – | runner has 1 screen | ⚠️ unverifiable |

Notes:
- **Pixelate (superseded, see Follow-ups)**: only 25% of pixels change. The synthetic checkerboard's 16 px squares partly line up with the pixelate blocks, and an aligned block averages to its own colour. The threshold is 15%. The image (`tool-pixelate.png`) shows the expected blocky region.
- **Edit ▸ Copy**: on the runner the overlay was not the key window (`overlayWasKey: false`), because a headless runner does not reliably make ShareX active. The driver therefore sends `copy:` through the overlay window's own responder chain (`handled: true`). Routing through `NSApp`'s key window was not verified on the runner.
- **Retina**: the runner is 1x. The 2x path was verified with a synthetic 2x frame, not a real Retina display.

## Other E2E checks
| Check | Result |
|---|---|
| Menu titles | ✅ |
| Settings window opens | ✅ |
| Settings survive relaunch (blue/8 rect, last region, saveToFile) | ✅ (`verify-settings.json`) |
| Re-entrancy: 1 visible overlay | ✅ |
| Previous app is frontmost after capture | ✅ |
| Hotkey ⌃⇧1 fires a capture | ✅ (synthetic CGEvent, not a physical key) |

## TLA+ model (`formal/Capture.tla`)
The model covers `CaptureCoordinator`, `OverlayController.close` and `report()`. Each MainActor turn between awaits is one atomic action, and the model includes the outer and inner (picked-window) tasks.

Run with: `java -cp tla2tools.jar tlc2.TLC -deadlock -workers 4 -config <cfg> Capture.tla`. Results are in `formal/*.out`.

| Config | OpenEditor | FixAlertFocus | Result |
|---|---|---|---|
| MC_bug_TRUE / MC_bug_FALSE | T / F | FALSE | **FocusRestoredWhenIdle violated** in 3 states: Capture → OuterAbort(alert) → idle with ShareX frontmost |
| MC_fixed_TRUE / MC_fixed_FALSE | T / F | TRUE | No error. 470 states generated, 95 distinct, all invariants and liveness properties hold |

- **Invariants**:
  - TypeOK
  - AtMostOneOverlay
  - IdleIsClean (idle ⇒ no overlay or task)
  - ExportOnlyFromEditing (clipboard written only from the editor, or directly when the editor is off)
  - FocusRestoredWhenIdle
- **Properties**:
  - NeverStuckBusy (`busy ~> ~busy`, under fairness)
  - CancelReturnsIdle
- **Mutation sanity check**: removing the `busy` guard in `capture()` makes TLC report an AtMostOneOverlay violation, so the model can find this kind of bug.

### TLA+ weak spots (macOS Developer review)
- `CancelReturnsIdle` is true by construction in the model (every cancel action sets the idle state directly), so it checks nothing beyond the action definitions.
- The alert-focus fix is modelled by its outcome (focus restored) rather than by how the code does it (`frontmostApplication` check, `activate()` result, `NSApp.hide` fallback); a code bug in that mechanism would not show up in TLC.
- Closing the overlay always counts focus as restored in the model; a terminated previous app was not modelled. The code now falls back to `NSApp.hide(nil)` for that case (see Follow-ups) and E2E covers it.

## Property tests (`Packages/ShareXCore/Tests/ShareXCoreTests/PropertyTests.swift` + existing `FuzzTests.swift`)
- **Crop normalisation**: exhaustive 12⁴ grid of drags. The result is nil or inside the bounds and at least 1 pt; it is the same in both drag directions; clamp is idempotent.
- **Geometry clamp**: 5000 random cases. The result is contained in both inputs.
- **Undo/redo inverse**: for n ≤ 8 edits (shapes and live crop) and every k ≤ n, undo k then redo k gives back the same state. Undoing everything gives the initial state, and one extra undo is a no-op.
- **Settings decode** (existing tests): decoding random or corrupted data never crashes and falls back to defaults. Sanitised settings are in range, idempotent, and round-trip.

## Bugs
1. **Fixed (product): focus stays on ShareX after an error alert.** `report()` shows an `NSAlert` for windowGone, denied permission or capture failure, which activates ShareX. The previous app was never reactivated, so ShareX stayed frontmost with no window, and the next Active Window capture had no target window and only beeped. Found by TLC.
   - Fix in `CaptureCoordinator.report`: remember the frontmost app before the alert. Afterwards, if ShareX is still frontmost, reactivate that app, or call `NSApp.hide` if there was none.
   - Not E2E-tested: no scenario forces an alert.
2. Harness only, all fixed:
   - `until()` default-argument overload did not compile
   - freehand expression was too complex for the type checker
   - Edit▸Copy needed the key window
   - editor Last Region drew outside the crop
   - rect colour after style persistence

## Not verified
- Multi-display (1 screen on the runner).
- Real Retina hardware (synthetic 2x only).
- Physical hotkey press.
- Real-SCK display frames with other apps' windows in them (the runner composites none).
- The error-alert focus fix, E2E.
- Real TCC permission prompt UX (granted through TCC.db).

## CI runs used: 5 (budget ~15)
| Run | Outcome |
|---|---|
| 41576624619 | E2E.swift did not compile |
| 41576827048 | First real-SCK E2E: 9 harness failures |
| 41577188439 | 3 harness failures |
| **41577460497** | **Green** |
| Doc commit | – |

Sample screenshots: `reviews/e2e/combined-rect-blur-arrow-crop-undo.png`, `tool-blur.png`, `tool-spotlight.png`, `freehand-lasso.png`, `auto-windowPicker.png` (real SCK), `editor-fullscreen.png`, `retina-2x-pipeline.png`, `runner-desktop.png`.

## Follow-ups after macOS Developer sign-off
- **Focus fallback**: `Focus.restore` (`App/Sources/CaptureCoordinator.swift`) activates the previous app only if it exists, is not ShareX, is not terminated, and `activate()` returns true; otherwise `NSApp.hide(nil)`. Used by `CaptureCoordinator.report` and `OverlayController` close.
- **Forced alert E2E**: `alert-windowGone-focus-restored` (seam `ScreenCapture.e2eForceWindowGone`, modal suppressed by `E2E.suppressAlerts`; `NSApp.activate()` and focus restore run as shipped) and `alert-no-previous-app-hides`.
- **Pixelate**: percent-changed threshold replaced by: every full block (tool strength, default 10 pt, × scale; lattice offset searched) in the region is uniform, the source had textured blocks, the region differs from source, nothing outside changed, and with the fixture (which now has black "SECRET 0123456789 password hunter2" text rows) fewer than half of the source's dark text pixels are still dark in the output (run 2 measured ~25%), and more than 20% of the region changed.
- **Lasso**: grid of ~1600 samples; every sample more than 3 pt from the triangle edge must be opaque inside and transparent outside (at least 100 of each).
- The real NSAlert modal is still not driven on CI.

### Follow-up runs
- Run [41578426160](https://github.com/Oiuhqw/sharex-mac/actions/runs/41578426160): red. The new pixelate check assumed 12 pt blocks (the pixelate default is 10), and the fixture text landed on the spotlight's single sample pixel. Both were fixed in the test; no app code changed.
- Run [41578811822](https://github.com/Oiuhqw/sharex-mac/actions/runs/41578811822): green, 48 pass + 1 unverifiable (multi-display). Pixelate: 150/150 blocks uniform at grid offset (0,0), 110 textured source blocks, 0% of source text pixels still dark. Lasso: 782/782 inside opaque, 798/798 outside transparent. Alert path: focus went back to the pattern app. Both `Focus.restore(nil)` and `Focus.restore(<terminated>)` hid ShareX. Note: for an exited pid, `NSRunningApplication(processIdentifier:)` returned nil, so the "terminated" case ran the nil path. The `isTerminated` branch is guarded in code but was not hit separately.
