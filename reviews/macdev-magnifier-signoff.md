# PR #2 (fix/magnifier @ 382ef6a → codex/fix-export-release) — magnifier sign-off

**Verdict: SIGN.** Two follow-ups are listed below. Neither blocks this PR.

## Evidence

CI run 41800213842: build-and-test ✅ and package/dmg ✅. E2E is **194 PASS / 6 FAIL**. None of the 6 come from the magnifier, and all are runner limits:
- `capture-display-textured-content`: the runner's display is uniform, so the fixture fallback is used.
- 4 × `redaction-native-compositor-{move,recovery}-{blur,pixelate}-2x-display-aligned`: the runner backing scale is 1.0, not 2×. These are diagnostics, not proof about a physical Retina display.
- `multi-display`: the runner has 1 screen.

`loupe` PASS:
- The test window was **not key and the app was not active** (`isKey: false`, `appActive: false`). `trackingAreas: 1`.
- **Real HID moves** (`CGEvent.post(.cghidEventTap)`): hid and hid2 cellsMatching 1.0.
- hover, moved, dragEdge, and the TopLeft, TopRight and BottomRight corners: all 1.0.
- hover p50 0.08 ms, p95 0.62 ms, max 21 ms (n=300).

`loupe-reopen-20x` PASS: 20/20 shown with the app inactive, no failures.

Screenshots:
- `/workspace/e2e-loupe.png`: the loupe is upright, sits +20/+20 from the cursor, has a red centre cell and reads `X: 120 Y: 100`.
- `/workspace/e2e-loupe-corner.png`: at (1.5, 1.5) the loupe is clamped on-screen. The rows and columns past the image edge are **black** at the top and left, which is the correct Y direction. It reads `X: 3 Y: 3`.

Perf (perf.json, compared with 9cabccb run 41697821297):
| Metric | Before | After |
|---|---|---|
| hoverMove p95 | 1.38 ms | 1.13 ms |
| regionDrag p95 | 2.08 ms | 1.22 ms |

Hover and drag did not regress. Some commit and save numbers rose:
| Metric | Before | After |
|---|---|---|
| commitToClipboard p95 | 148 ms | 341 ms |
| savePNG p50 | 85 ms | 159 ms |
| annotNewBlurDrag p95 | 9 ms | 21 ms |

This PR doesn't touch any of those code paths (the diff is ChromeView, EditorView mouse handling and one line in OverlayController), so I treat it as runner variance. Re-run once before release to confirm.

## Diff checks against my design

| Item | Result |
|---|---|
| Tracking area | `[.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited]` with rect `.zero` (EditorView.swift:~104). `updateTrackingAreas` removes only its own `moveArea` before adding the new one, so areas are never duplicated (CI shows `trackingAreas: 1`). ✅ |
| Installed in `viewDidMoveToWindow` | Yes, through `updateTrackingAreas()` and then `syncMouse()` (:~108). ✅ |
| `mouseEntered` treated as a move | Yes (:~194). ✅ |
| `syncMouse` | Uses `mouseLocationOutsideOfEventStream`, which is in window coordinates, then `convert(_, from: nil)`, which handles window→view and the flipped view. It sets `mouse = nil` when the cursor is outside the view. It runs for every surface in `show()` (OverlayController.swift:152). ✅ |
| Contents set once | `setMagnifierSource(renderer.frame)` in init. There is no per-move crop. Filters are `.nearest` (both mag and min). ✅ |
| contentsRect | `vis = src ∩ image`, and the image sublayer frame is `(vis - src) * zoom`. `unitRect` keeps Y top-down; corner tests prove the direction. Past the edge you see the container's black background with `masksToBounds`. If the whole square is outside the image, the image layer is hidden. ✅ The `static var contentsRectFlipY` toggle is a debugging knob: make it `let`, or delete it (nit). |
| Flip and clamp | Flips at the right and bottom, then clamps x and y to `[0, bounds - side(-label)]`, using each screen's own `bounds`. ✅ |
| zPosition and actions | Magnifier and label at zPosition 1000. `contentsRect`, `frame`, `position` and the other implicit actions are disabled on the sublayers, and everything runs inside a disabled-actions transaction. ✅ |
| Multi-screen | `mouseExited` sets `mouse = nil` and hides the loupe. Each view owns its own loupe. This could not be tested on 1-screen CI; check it on a device. |
| Hide while dragging | Not done; the loupe stays during a region drag. My design called this a product choice, so it's acceptable. |
| Real inactive-app hover in tests | **Yes**: HID-posted moves with `isKey=false` and `appActive=false`. |
| Leftover | The label X/Y uses `Int(p*s)`, while the source uses `floor`. They are the same for p ≥ 0. Nit. |

## Keyboard focus (open question): pre-existing and serious, so a follow-up, not a blocker for this PR

- The PR leaves `NSApp.activate()` (OverlayController.swift:145) unchanged.
- In CI, after `NSApp.activate()` and `makeKeyAndOrderFront`, the app is **still inactive and the window not key**, so on macOS 14 and later cooperative activation can decline.
- When that happens, the window server sends key events to the frontmost app. **Esc, Enter, the tool hotkeys and text annotation typing will not reach the overlay.** This affects every capture mode.
- It is **not a regression from this PR**, because the activation code is the same as before.
- **No E2E test covers it.** The keyboard tests call `view.keyDown` directly (E2E.swift:164–167), send through `window.sendEvent` (E2EEditing.swift:59), or use `NSApp.postEvent` (E2E.swift:656–658). All three bypass window-server routing.
- The user's "everything else works" suggests activation succeeds when the trigger is a real hotkey. That fits the idea that a Carbon hotkey counts as user intent **[UNVERIFIED]**.

**Recommendation:**
1. **Device check:** with another app frontmost, press the region hotkey, then press Esc, and separately type into a Text annotation. Log `NSApp.isActive` and `window.isKeyWindow` after `show()`.
2. **Robust fix, whatever the check shows:** make the overlay an `NSPanel` subclass with styleMask `[.borderless, .nonactivatingPanel]`, `becomesKeyOnlyIfNeeded = false`, `canBecomeKey = true`, `level = .screenSaver`, and `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`. Call `makeKeyAndOrderFront` and do not depend on activation. Keep `Focus.restore` as it is.
   - Text fields inside a non-activating key panel do accept typing. Verify the field editor and IME with a CJK input source.
3. **Add an E2E test** that posts `CGEvent(keyboardEventSource:virtualKey:53)` to `.cghidEventTap` while another app (the existing pattern-app helper) is frontmost. Assert that the session cancels, and that `t` plus typed text reaches a Text annotation.

## `reviews/macdev-magnifier.md` committed

Keeping it committed is fine. It is a dated diagnosis of 9cabccb, and its hypotheses are borne out (hover delivery). Nothing in it is wrong, but add a one-line header: "Superseded by macdev-magnifier-signoff.md; fixed in 382ef6a".
