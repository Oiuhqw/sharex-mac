> Historical review of an earlier revision. See [the review index](README.md) for current evidence and validation status.

# macOS developer sign-off: perf + security pass (`7910f92..61060c2`), 2026-11-03 (UTC+8)

## Verdict: **SIGN**, with one required on-device check before the DMG is published

I found no correctness or security regression:
- The E2E hooks cannot be reached in release; they are a compile-time flag.
- There is no clipboard race: `busy` stays set through the encode.
- There is no stale-capture output path: window captures always fetch fresh content.

**Required before release (not proven broken):** nothing in CI checks the on-screen overlay's orientation or dim. The one probe built for this reads `layerOrientation.ok=false` (topLeft 214, bottomRight 228; it expected the undimmed crop to be brighter by more than 40). `perf-pass.md` says "E2E visual tests cover orientation". That is wrong: the E2E PNGs are *exported* images from `Renderer`, not what is on screen, and with `sharingType = .none` SCK can no longer see the overlay at all. Someone has to look at it on a Mac once: is the frozen frame upright in the selection phase, and does the dim hole sit under the cursor? [UNVERIFIED]

## CI, checked with `gh`
- **AFTER 41631402963 (macOS)**: success at headSha `ba5b99f`. HEAD `61060c2` differs only in `dmg.yml` and docs.
  - All 16 steps green, including Core tests, E2E, Release perf build and the perf scenario.
  - E2E artifact: **49 results, 48 pass + 1 unverifiable (multi-display)**, `pass: true`. The doc's "48/48" and "multi-display reports FAIL" are both slightly wrong.
  - `perf.json` matches every number in the table: hover 0.10/0.20, region 0.15/0.25, rect 2.97/17.64, pen 1.81/17.03, highlighter 2.03/18.17, move-blur 1.88/17.44, new-blur 9.61/14.29, main-thread commit 20.9/21.3, async pipeline 111.7/112.0, capture→overlay 47.2/48.9 (ms, p50/p95; n=120 per drag).
  - BEFORE 41628832920 is also green, at `7910f92`.
- **DMG 41634710703**: success at `59f13ed`.
  - The `strings` check printed "no --e2e strings".
  - Signature: `flags=0x10002(adhoc,runtime)`, `Signature=adhoc`, `TeamIdentifier=not set`.
  - Universal binary (x86_64 + arm64); `codesign --verify --strict` reports "valid on disk"; `spctl` "rejected", as expected; the 8 s launch smoke passed.
  - The artifact's `ShareX.dmg` sha256 `d985d09c…0d86` matches the published `.sha256`; I downloaded both and checked.
  - **The quarantine probe is broken, and the failure is masked.** The log shows `timeout: command not found` (macOS has no GNU `timeout`), so the step exits 127 and `continue-on-error` turns it green. As a result:
    - the "Gatekeeper assessment: rejected (unnotarized)" line is the `||` fallback message; `spctl` never ran in that step;
    - the documented `xattr -dr` workaround was **never verified**.
  - Fix: use `gtimeout` (coreutils) or a `perl -e 'alarm 60; exec @ARGV'` wrapper.

## Focus areas

### 1. Layer frame + dirty rects: **correct by reading; on-screen check required**
- **Frozen frame**: `FrameView` (EditorLayers.swift:20-30) uses `contents = CGImage`, `contentsGravity = .resize` and `layerContentsRedrawPolicy = .never`.
  - With `.resize`, the image is fitted to the layer bounds, so `contentsScale` does not affect sharpness or size for image contents. Moving to another screen is covered.
  - Filters: `.nearest` for 1:1, `.linear`/`.trilinear` when smoothing.
  - **Flipping is the open risk.** `PassThroughView.isFlipped = true` (:9), and how CA draws a CGImage `contents` in a flipped, layer-backed NSView is exactly the probe that fails above. [UNVERIFIED]
- **Labels**: `contentsScale` follows `viewDidChangeBackingProperties` (:132-136), so it updates when the window moves to another screen. `CAShapeLayer` paths are vector, so their scale does not matter.
- **AnnotationsView** (:37-91) is drawn by AppKit (`.onSetNeedsDisplay`), so AppKit manages its backing scale.
  - Dirty rects are in **points** and `.integral` (:76). AppKit converts them to pixels and rounds outwards, so there are no fractional seams at 2x.
  - Padding: `reach = bounds ± (width×4 + 12)` (:80-83). That covers the stroke, the round caps and the arrow head (`len = max(10, w×4)`, Renderer.swift:66).
  - Blur and pixelate patches stay inside `rect`. Marks have no shadows.
  - `.text`, `.step` and `.spotlight` trigger a full redraw (:65), so the unbounded spotlight dim and text metrics are safe.
- **Stale regions**: `sync` unions the *old and new* reach of every changed mark (:70), plus removed marks (:71). On a z-order change it unions everything (:73-75); a change in the hidden ID causes a full redraw (:60).
  - Draw-side culling (Renderer.swift draw `clip:`) uses the same `reach()` and the same exceptions, so invalidation and culling cannot disagree. I found no miss.
- **The union is a single bounding rect.** Two marks far apart, for example an undo that touches both, redraw the whole box between them. This is correct, just not minimal. Calling `setNeedsDisplay(in:)` per rect would let AppKit keep a rect list. Non-blocking.
- **Redundant layer**: in editing, `AnnotationsView` is opaque and draws the frame itself (:88), so `FrameView` underneath is pure overdraw in that phase. It is also why every drag touches a full-screen backing store (see the p95 section).

### 2. Shared Metal CIContext: **OK**
- `private static let sharedCI` (Renderer.swift:150-155) sits in a `@MainActor final class Renderer` (:9-10), so every use is on the main actor.
  - The off-main work, `decorateOffMain` and `encode` (Export.swift:35, :60), is pure CG/ImageIO and never touches CI.
  - `effectCache` and `ciFrame` are per-instance, main-actor state. There is no shared mutable cache.
- `.cacheIntermediates: false` and `.workingColorSpace: Imaging.colorSpace` are set. Output goes through `createCGImage(…, colorSpace: frame.colorSpace ?? Imaging.colorSpace)`, so the frame's own colour space is kept.
- If no Metal device exists, it falls back to the default context.
- The only `@unchecked Sendable` is `ImageBox` (Export.swift:144). It wraps an immutable `CGImage`, which is thread-safe, so it hides no race. Use `sending` or a typed `nonisolated(unsafe) let` once the SDK marks CGImage Sendable.
- `Encoded` is a real `Sendable` of two `Data` values. The project builds with Swift 6 and `SWIFT_STRICT_CONCURRENCY: complete` (project.yml:15, :46).

### 3. SCShareableContent cache: **OK; two small hazards**
- The cache is used **only for display capture** (ScreenCapture.swift:89-94, :115). Window capture always fetches fresh (:151), so a stale `SCWindow` cannot produce a wrong window: one that is gone gives `windowGone` (:152).
- Invalidation:
  - a 60 s TTL (:90);
  - a check that every requested display ID is present (:91);
  - clearing on `didChangeScreenParametersNotification` (:79-82), which covers hot-plug and resolution or arrangement changes.
  - Opening, closing or moving windows does not matter for display capture, because the own-app exclusion filters by application, not by window.
- Hazard (a): `prefetch()` starts an unawaited Task (:85-87). A fetch already in flight when the screens change can finish *after* the notification and write pre-change content. The ID check catches unplug; a resolution change on the same ID would reuse an old `SCDisplay.width/height` for `config.width/height` (:126-127) for up to 60 s. That gives a wrongly sized or scaled frame, not wrong content.
  - Fix: a generation counter bumped by the notification, and only store a result when the generation is unchanged. Alternatively, size from `screen.frame × backingScaleFactor`.
  - [UNVERIFIED] whether SCK rescales or crops in that case.
- Hazard (b): the `ours` exclusion list (:118) comes from content that may be 60 s old. The PID is stable, so this is fine.

### 4. Off-main encode / ordering: **no race**
- `deliver` (CaptureCoordinator.swift ~165-182) does decorate and encode in `Task.detached`, then `Export.write` **on main**, then saves the *same PNG bytes* (`savePNGData`, Export.swift:98). The clipboard and the file cannot differ.
- Ordering does not need a generation token, because **`busy` stays true for the whole encode**:
  - in the editor-finished path, `overlay = nil`, then `await deliver`, then `busy = false` (CaptureCoordinator.swift:85-91, :115-119);
  - in the non-editor paths, `deliver` is awaited inside `run`, before `defer { if overlay == nil { busy = false } }` (:18).
  - `capture()` returns early when `busy` (:14). A new capture therefore cannot start, and Esc has nothing to cancel because the overlay is already gone.
  - Side effect: a hotkey pressed during the ~112 ms encode is dropped silently. Before, the main-thread stall did the same.
- File collisions:
  - `writePNG` uses `.withoutOverwriting` (O_EXCL) and retries 5 names (Export.swift:128-139);
  - `busy` serializes captures;
  - even concurrent writers could not overwrite each other.
- Folder handling: `resolveFolder` resolves symlinks and requires a writable directory. Good.

### 5. `sharingType = .none`: **correctly scoped**
- It is set only on the overlay windows (OverlayController.swift:127) and the countdown HUD (Countdown.swift:20). The perf-only E2E window uses `.readOnly` (E2EPerf.swift:94).
- The menu-bar item, Settings and alerts are unaffected.
- Side effect: on macOS 15+, `.none` also hides these windows from the user's *own* screenshots and recordings (⌘⇧5, QuickTime, other SCK apps) and from SCK window lists. For a frozen-frame overlay this is the intent. It also means **no automated SCK test can see the overlay any more** (see the required check above). [UNVERIFIED] behaviour on macOS 27.

### 6. SHAREX_E2E gating: **sound (compile-time)**
- `E2E.swift` and `E2EPerf.swift` are wrapped entirely in `#if SHAREX_E2E` (line 2 of each). The call sites are gated at App.swift:10, :60, OverlayController.swift:34 and CaptureCoordinator.swift:153.
- In release, the `ScreenCapture` seams are `static let … = nil/false` (ScreenCapture.swift:52-55). They cannot be assigned, and the compiler drops the branches. `Permissions.swift:11` therefore reads a constant nil.
- The flag is set **only** on the CI command line (`SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) SHAREX_E2E'`, macos.yml:51, :78). It is not in project.yml, xcconfig or the env, so no runtime env var or `--e2e` argument can switch it on.
- The DMG `strings` gate passed. One weakness: the grep looks only for `--e2e|E2E PERF|e2e-helper`, so `#if SHAREX_E2E` code with no such strings would get through. Adding a check for a unique symbol (e.g. `nm … | grep E2E`) would close that.

### 7. Hardened runtime + ad-hoc signing: **correct and disclosed**
- `flags=0x10002(adhoc,runtime)`, signed inside-out without `--deep` (dmg.yml:39-46).
- There is **no entitlements file**. Screen Recording is a TCC grant, not an entitlement, and the app needs no JIT, library-validation or other exemptions, so running under the hardened runtime breaks nothing; the launch smoke passed.
- Ad-hoc signing makes the code identity the cdhash, which changes on every build, so **TCC grants are lost on every update**. This is disclosed: README.md:10-11 for dev builds. Ask: say the same in "Installing the DMG" (README:98-106), i.e. "re-grant Screen Recording after every update; remove the old entry first".
- Notarization requires a Developer ID certificate. This is stated in README:100-101 and listed as a TODO (README:96).

### 8. Annotation drag p95 ≈ 17 ms on the 1x runner: diagnosis and fix
- **The data**: p50 is 1.8–3.0 ms and p95 is 17–18 ms, but the **mean is about 8.1 ms**. The distribution is bimodal: roughly 35–40% of events cost 16–20 ms and the rest about 2 ms.
  - Hover and region drag, which only touch shape layers, are 0.2 ms.
  - So the cost is neither event handling nor rasterising the mark. It is pushing the **full-screen `AnnotationsView` backing store** (3456×2234×4 ≈ 30 MB, opaque, EditorLayers.swift:37-49, :85-89) on every drag event.
- **Most likely cause**: each `frame()` (E2EPerf.swift:37-42) does `displayIfNeeded()` and then `CATransaction.flush()`. After a partial `setNeedsDisplay(in:)`, CA has to give AppKit a writable backing surface.
  - While the WindowServer still holds the previous IOSurface, CA either blocks until it is released, which happens at the next vsync, or copies the full 30 MB into a new surface.
  - On a 60 Hz, software-composited runner, that wait is about **one refresh (16.7 ms)**. This fits a max around 20 ms and the about-1-in-3 hit rate.
  - **So the measurement is partly frame-locked.** The p95 is mostly "one 60 Hz frame of back-pressure", not CPU work.
  - The reverted 256 pt tiling made p50 worse (more layers, more commits) without removing the surface wait, which also fits.
  - New-blur p50 of 9.6 ms is a separate cost: the live effect's key includes `rect` (Renderer.swift:126-128), so a full CI blur of the growing rect runs on every event. On the runner, that CI work is probably software-rendered.
- **Fix**: keep the big surface still during a drag.
  1. Draw the in-progress mark in a **transient, small layer** above `AnnotationsView`:
     - a `CAShapeLayer` for rect, line, arrow and pen;
     - a `CALayer` with `compositingFilter = "multiplyBlendMode"` for the highlighter;
     - a reach-sized `CALayer` whose `contents` is the CI patch for blur and pixelate.
     Then commit once into `AnnotationsView` on mouse-up. Moving an existing mark works the same way: hide it in the big view once at mouse-down, then drag its proxy layer.
  2. Make `AnnotationsView` transparent and stop it drawing the frame (`FrameView` is already underneath). Blend modes are handled by the proxy layer's `compositingFilter`. Alternatively keep it opaque but only redraw it on commit.
  3. Live blur and pixelate: render from a downsampled or cached `CIImage` of the frame, cropped to the rect, through the shared Metal context. Cache by rect *size* and translate when only the position changes.
  4. Measurement: report main-thread time *without* `CATransaction.flush`, plus a separate commit-to-present figure (CADisplayLink timestamp or `CAMetalLayer`/`presentedTime`), and the raw sample histogram. A single p95 hides the bimodality.
- **Expected on an M5 Pro at 120 Hz** [UNVERIFIED]:
  - drags: main-thread time per event under 1 ms, because only one small layer changes; no 8.3 ms surface-wait spikes; p95 well under the **8.3 ms** budget;
  - new blur: about 1–3 ms on Metal.
  - Without the fix, the same design would hit a quantum of **about 8.3 ms** at 120 Hz, right on the edge of the budget. The GPU compositor will make the copy cheaper, but the wait remains.

## Required (before publishing the DMG)
1. Check on a real Mac that the overlay frame is upright and the dim and crop hole match the cursor, in both the selection and editing phases. Then fix the probe so it can actually read the orientation: use a top/bottom-asymmetric frame and upload the captured PNG. [UNVERIFIED]
2. Fix the DMG quarantine probe: `timeout` does not exist on macOS (exit 127, masked by `continue-on-error`), so Gatekeeper and the `xattr` workaround were never actually exercised.

## Requested (non-blocking)
3. Draw live drags in proxy layers, as in the p95 section, and change the measurement to report main-thread time and presentation separately.
4. Guard the prefetch race with a generation counter, or size from `NSScreen` instead of a cached `SCDisplay`.
5. README "Installing the DMG": say Screen Recording must be re-granted after every update (ad-hoc cdhash).
6. Strengthen the DMG gate with a symbol check (`nm`/`strings` for `E2E` type names), not only the flag strings.
7. Docs: "48/48" should be 48 pass + 1 unverifiable (49 results), and multi-display is unverifiable, not FAIL. Remove the claim that E2E covers on-screen orientation.
8. Optional: replace the single-rect union with per-rect `setNeedsDisplay(in:)`.
