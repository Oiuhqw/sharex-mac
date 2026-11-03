# macOS developer sign-off: E2E run + formal verification — 2026-11-03 (UTC+8)

## Verdict: **SIGN** (with requested follow-ups, none blocking)

I found no unsound test that would pass a broken feature, no weakened redaction and no app regression. The CI claim is confirmed independently (below). Re-run here: `swift test` **59/59 pass**; `swiftc -parse` passes on all App/Sources files (now including E2E.swift).

## CI check (done, not trusted)
`gh run view 41577460497 -R Oiuhqw/sharex-mac`:
- **success**; headSha `ac10a33` (the commit before the docs-only `ade7e41`).
- Every step is green, including "E2E (real app…)".
- Downloaded artifact `e2e/results.json`: **47 results: 46 pass, 1 `unverifiable` (multi-display)**, `pass: true`, `frameSource: sck-window+fixture-display`. It is byte-for-byte identical (normalised JSON) to the committed `reviews/e2e/results.json`.

The gate is real. `scripts/e2e.sh` ends with `[ $RC -eq 0 ] && [ $VRC -eq 0 ]`, and `finishRun` (E2E.swift:101-107) exits 2 if any result is neither pass nor unverifiable. A watchdog (E2E.swift:97) records a FAIL on a hang.

I also checked the earlier run 41576827048 (real black SCK display frames, `frameSource: sck`). Every display path passed size, clipboard and saved-file checks. Only the pixel-change checks failed (highlighter, blur, pixelate, spotlight) plus harness items (copy-menu-action, editor-*). This matches the report. The public API returns 404 (private repo), so I used authenticated `gh`.

## (1) Clipboard matrix: **sound**
`checkClipboard`, E2E.swift:206-235:
- **One item with public.png AND public.tiff**: `items.count == 1 && types.contains(png) && types.contains(tiff)` (:232). The types come from that single item (:210).
- **Decoded pixels, not bytes**: both are decoded with ImageIO and redrawn into the same 8-bit **sRGB premultipliedLast** context (`bitmap`, :175-184), then compared with `pbm.px == tbm.px` (:219, :233).
  - Colour space is normalised. Alpha is handled; premultiplied, so RGB under alpha 0 is ignored, which is correct for equality.
- **Saved file == clipboard**: decoded with the same `bitmap()`, `savedEq` (:223-224). It requires exactly one new file (:220-223), and the name regex and DPI are checked.
- **Replace, not append**:
  - The sentinel string is seeded first (`markClipboard`, :199-202).
  - The checks are `changeCount != m.change` and `string(forType: .string) == nil` (:234).
  - There is also a dedicated back-to-back test (:418-427: 1 item, newest size, changeCount bumped).
- **Cancel unchanged**: `unchanged()` (:238-243) requires `changeCount == m.change` and the sentinel still present, with no new file, `busy == false` and no overlay. Six cancel paths use it (:532-571).
  - Countdown Esc is a real negative test. The delay is 1 s and the check runs after 1.5 s, so a failed Esc would capture and fail the check.

Minor gaps (not blocking):
- The lasso alpha check samples only 2 pixels (:484).
- `drop-shadow`, `save-naming-collision` and `save-off` check size and files, not the full clipboard matrix (:590-604).
- Edit ▸ Copy is driven by `tryToPerform` on the overlay's responder chain (:409-410), not the real main-menu key equivalent through `NSApp.keyWindow`. This is disclosed. [UNVERIFIED] on a real Mac.

## (2) Checkerboard fixture for display frames: **acceptable, disclosed, but it bypasses all of display SCK**
- `ScreenCapture.freeze` returns early when `e2eDisplayFixture` is set (ScreenCapture.swift:75-80). In the green run, **no SCK display code runs** for display captures:
  - `shareableContent`;
  - the `SCContentFilter(display:excludingApplications:)` filter, which excludes our own windows;
  - the width/height config;
  - sRGB and `showsCursor`;
  - `SCStreamError` mapping.
- What still runs is real: the overlay, editor, Renderer and CoreImage, flatten/decorate, pasteboard and save. **Window captures are real SCK** (`captureWindow` only short-circuits on `e2eFixture`, :105, which was not set). `auto-windowPicker.png` shows the real "E2E Pattern" window.
- Because the fixture is generated at `NSScreen` size, the display-size assertions (`auto-fullscreen` 1024×768 etc.) are tautological in the green run. Real-SCK display sizing is covered only by run 41576827048, which passed it.
- Untested: whether the overlay and countdown HUD are excluded from the frame, Show cursor, real desktop content, and multi-display stitch. The report's "Frame source" section and "Not verified" list disclose this. The swap is triggered only by a detected uniform frame (E2E.swift:280-283), not unconditionally. Good.
- Request: state explicitly in the report that display-capture dimensions in the green run come from the fixture, not SCK.

## (3) Pixelate threshold 30% → 15%: **legitimate test change, redaction not weakened**
- The metric `diffFrac` (E2E.swift:366-372) is the *fraction of pixels in the inner box whose RGB moved by more than 0.02 from the baseline*. It is a "did the filter run" check, not a readability measure. The threshold is only in the test (:336). The redaction code is unchanged: `pixelateBlock = max(2, strength × scale)` gives 10 px at 1x (Geometry.swift:190-193; Renderer.swift:104-120).
- I measured `tool-pixelate.png` against `region-baseline.png` here:
  - 25.3% changed inside, 0% outside;
  - **all 150 10×10 blocks are perfectly uniform**;
  - each block's colour is a colour found in the original block (CIPixellate takes one colour per block).
- On a 16 px, 4-colour checker, many blocks fall inside one square and keep its colour, so about 25% is the expected result, not a weak filter. The image confirms real blocks (it looks like a coarser checker).
- Readability: at 10 px blocks (20 px on Retina), a block is as large as or larger than a body-text glyph, so text is reduced to blobs. Text at the 15% threshold: a correct pixelate over dark-on-white text changes only the pixels near strokes, so the fraction says nothing about legibility either way. A no-op filter still fails (0%).
- Request (non-blocking): replace the fraction check with **block uniformity** (every block constant, as measured above) plus a text fixture ("E2E TEXT" at 13 pt) where glyph-sized structure must be gone. The 30% → 15% change hides nothing, but the metric was never a redaction metric.

## (4) `report()` focus fix (CaptureCoordinator.swift:130-150): **correct, no regression; two edge cases**
How it works:
- It captures `frontmostApplication` before the alert, and in a `defer` it acts only if ShareX is still frontmost.
- If so, it calls `previous.activate()` when `previous` is another app, else `NSApp.hide(nil)`.
- For the `noPermission` path, the alert's "Open System Settings" leaves Settings frontmost, so the defer does nothing. Correct.

Edge cases:
- **Terminated previous app**: `activate()` on a terminated app returns false, and the return value is ignored, so ShareX stays frontmost with no window. This is the same symptom the fix targets, in a rare case. Request: `if let p = previous, p != .current, !p.isTerminated, p.activate() {} else { NSApp.hide(nil) }`.
- **Stale `previous`**: `report` runs right after `OverlayController.close`, which itself called `previousApp.activate()` (OverlayController.swift:156). Activation is async, so `frontmostApplication` may still read ShareX, and `previous` is then `.current`, which leads to `NSApp.hide`. Hide also hands focus to the next app, so the result is fine.
- **Modal timing**: `runModal()` blocks, and the defer runs after the alert is dismissed. Ordering is correct. In the default branch (beep only), there is no alert, so the defer is usually a no-op.
- **hide vs activate**: only one of them runs, so there is no ordering conflict.
- **macOS 14 cooperative activation**: ShareX is the active app at that point, so `NSRunningApplication.activate()` is permitted. Calling `NSApp.yieldActivation(to: previous)` first would be the documented pattern on 14+. [UNVERIFIED] whether it is needed in practice.
- **LSUIElement / accessory policy**: `NSApp.hide` works for accessory apps; the app never switches to `.regular`, so the Dock is unaffected.
- **Stage Manager**: reactivating may switch stages back. That is the desired behaviour, but [UNVERIFIED].
- **Not E2E-tested**: no scenario forces an alert. This is disclosed.

## TLA+ (`formal/Capture.tla`, `MC_*.cfg`, `MC_*.out`)
- **TLC output exists.**
  - `MC_bug_*` reports `FocusRestoredWhenIdle` violated with a trace.
  - `MC_fixed_TRUE` reports "No error… 470 states, 95 distinct, depth 13".
  - The configs list 5 invariants and 2 properties.
- **Real states**: it models the real coordinator variables:
  - `busy`;
  - the overlay count;
  - the outer and inner (picked-window) tasks;
  - the phase;
  - focus and previous app;
  - legal delivery.
  The `defer { if overlay == nil { busy = false } }` behaviour is modelled (Capture.tla:51). The action granularity of one MainActor turn per atomic step is right. `AtMostOneOverlay`, `IdleIsClean`, `ExportOnlyFromEditing` and `NeverStuckBusy` are meaningful, and the mutation check (removing the busy guard) shows the model can find this kind of bug.
- **Weaknesses** (non-blocking):
  - `CancelReturnsIdle` (`[][Cancel => ~busy']`) is a tautology, because `Cancel` sets `busy' = FALSE` itself (:65).
  - The fix is modelled as `Alert == focus' = focus` (:29). That is the *intended outcome*, not the code's mechanism (snapshot, then re-activate), so it cannot catch the terminated-app case above.
  - `CloseOverlay` always sets `focus' = "other"` (:37), so it assumes reactivation never fails.
  - Not modelled: the countdown, `show()` with no surfaces, multiple displays.
  - `TypeOK` omits `outer`, `inner` and `phase`.
  - Liveness relies on strong fairness of the user finishing or cancelling. That is fine, but it should be stated.

## Unverifiable test honesty: **honest**
Multi-display is recorded with `status: "unverifiable"` only when the screen count is ≤ 1 (E2E.swift:360-361), and it is listed under "Not verified". Note that `unverifiable` counts as passing the CI gate (:102). So does the hotkey test if the CGEvent post is refused (:638-639); it actually passed. Other honest disclosures: the synthetic 2x Retina frame and the TCC.db grant.

## Requested changes (non-blocking)
1. `report()`: fall back to `NSApp.hide` when `previous` is terminated or `activate()` returns false; consider `yieldActivation(to:)`.
2. Pixelate E2E: assert block uniformity and add a text fixture instead of (or as well as) the changed-fraction check.
3. Report: say that display-capture sizes in the green run come from the fixture, and that real-SCK display sizing was proven in 41576827048.
4. TLA: drop or replace the tautological `CancelReturnsIdle`; model the fix mechanism (snapshot, then reactivate, which may fail) and failed reactivation in `CloseOverlay`.
5. Mac-only, [UNVERIFIED]:
   - real-display SCK with real windows and overlay exclusion;
   - multi-display;
   - real Retina;
   - the physical hotkey;
   - Edit ▸ Copy through the main menu;
   - the alert-focus fix.
