> Historical review of an earlier revision. See [the review index](README.md) for current evidence and validation status.

# Final Skeptic review: sharex-mac PR #2 (fix/magnifier @ 382ef6a)

## VERDICT: BLOCK for release claims on macOS 27 / M5 Pro / 120Hz. SIGN for merging the PR as a CI-verified fix.

CI run 41800213842 is green and ran on HEAD 382ef6a (`gh run view` headSha matches). It ran on **macos-15-arm64, ProductVersion 15.8.2** (job log, Toolchain step), with one screen, a backing scale of 1 and a 60Hz vsync. That isn't macOS 27, isn't an M5 Pro, isn't Retina and isn't 120Hz. Result: 194 of 200 pass. The other 6 are `status: unverifiable`, not failures (CI artifact `e2e/results.json`).

The tests are better than usual and much of the clipboard proof is real. But the three headline claims are each proven one level below what's being claimed.

## Ranked findings

1. **Every capture test runs on a fixture image, not a real screen capture.** `frameSource: "sck-window+fixture-display"` is on every result. `capture-display-textured-content` is "unverifiable" because the runner's display frame is uniform black (App/Sources/E2E.swift:280-300, e.g. `ScreenCapture.e2eDisplayFixture = { checker(...) }`). So "the clipboard holds the processed capture" is proven for a synthetic frame pushed in after the ScreenCaptureKit (SCK) call. It isn't proven for real display pixels, color or scale. Only window captures are native.
2. **The "20/20 reopen" loupe test skips the app's own open path.** E2ELoupe.swift:91-95 builds `EditorView` and `OverlayWindow` itself, calls `orderFrontRegardless()`, and then calls `v.syncMouse()` **from the test**. The real path is hotkey → CaptureCoordinator → OverlayController.swift:153 (`s.view.syncMouse()`), and none of it runs. A regression where OverlayController stops seeding the mouse would still pass 20/20. All 20 opens happen in one process, on one screen, at fixed seeded positions (line 87), with a 150 ms + 250 ms settle (lines 90, 97). It never covers a fresh launch, the first-ever overlay, or the app being active (`appActive:false`). Statistically, 20/20 only bounds the failure rate below about 14% at 95% (rule of three: 3/20). That isn't "reliable."
3. **The loupe is never tested at Retina scale.** The fixture is 2x (E2ELoupe.swift:12-15), but the captured window comes back at `px:[300,240]` for a 300×240 pt window. Backing scale is 1, so the check at :36 (`kx = m.w/size.width = 1`) samples a downsampled view. The 2x redaction compositor tests say the same thing about themselves ("does not verify a physical Retina compositor", status unverifiable). On a real M5 Pro (2x), how loupe cells line up with source pixels is unproven.
4. **The perf numbers are mostly function timings, and the frame data is 60Hz.** `hoverMs` p95 0.616 ms (pass gate `p95 < 2`, E2ELoupe.swift:174) times a direct call to `v2.mouseMoved(with:)` plus `CATransaction.flush()` (:168). It skips the event path, the WindowServer and the actual drawing. The `*_onScreen_ms` p50 ≈ 16.6 ms (e.g. `annotPenDrag2x_onScreen_ms`, perf.json) is just the 60Hz vsync, so you can't tell what headroom exists at 8.33 ms/120Hz. Worse, `annotNewBlurDrag2x_onScreen_ms` p95 is 49.9 ms and `annotMoveBlur2x_onScreen` p95 is 28.9 ms. That misses 120Hz by 3–6 frames even on this runner. Sample sizes are small (n=5 for `captureToOverlayShown_runner_ms` and `commitMainThreadOnly2x_ms`; n=12 for the paired renders). There's one run, no cold vs warm split, and no variance across runs. The 1000-mixed render p95 is 16.3 ms, which is 2 frames at 120Hz.
5. **The clipboard check never looks at color space, HDR or wide gamut.** `checkClipboard` (E2E.swift:218-247) compares PNG pixels to TIFF pixels to the saved file, plus size and item count. It never reads the ICC profile or color space. The fixture is drawn in sRGB (E2ELoupe.swift:18) and the loupe capture forces `cfg.colorSpaceName = sRGB` (:63). A built-in Display P3 / XDR panel is the default on M5 Pro, and nothing tests it. `savedDPI` is checked but not asserted on 1x paths.
6. **Multi-display: never tested.** `multi-display` is `screens:1`, unverifiable. Mixed scale and mixed refresh (a 120Hz built-in plus a 60Hz external) aren't covered at all.
7. **The hotkey test is synthetic.** `hotkey-ctrl-shift-1` reports "synthetic CGEvent; a physical key press is not testable". On CI the permissions come from writing TCC.db directly with sudo sqlite while SIP is off (scripts/perf.sh grant(); e2e.sh is similar, UNVERIFIED line-by-line). The first-run, denied and revoked permission flows a real user hits never run.
8. **Notarization: none.** dmg.yml header: "No Developer ID / notarization ... Gatekeeper still rejects it." The app is ad-hoc signed with Hardened Runtime, and the quarantine probe only checks that the `xattr -dr` workaround launches. That's a release-UX blocker for normal users, and it's disclosed.

## Credit (real)
- The clipboard check is a real proof of the final image, not a changeCount proxy. `markClipboard` (E2E.swift:211-215) clears the clipboard and writes a sentinel. `checkClipboard` then requires exactly one item, both PNG and TIFF types, the exact expected pixel size, TIFF pixels equal to PNG pixels, the saved file's pixels equal to the PNG's, the sentinel gone, and changeCount moved (:244-246). Tool tests add a pixel check on the clipboard PNG (E2EEditing.swift:85-94; e.g. `tool-pixelate changedInside 0.25 / changedOutside 0`). `retina-2x-pipeline` asserts 600×400 px for 300×200 pt and DPI 144.
- Ordering: `regionCapture` waits for `!coord.busy` before reading (E2E.swift:274-277). `deliver` encodes after decorating and writes the clipboard on the main thread (CaptureCoordinator.swift:164-185). A write before processing finished would fail the size or pixel checks. I didn't trace in code that `busy` clears only after `delivery.finish` (UNVERIFIED), but the sentinel and pixel checks cover it in practice.
- The loupe check really reads pixels. Each frame pixel encodes its own coordinates (E2ELoupe.swift:7-21). The check decodes all 225 cells from an SCK capture of the real overlay window (:35-55, :57-67). The CI corner, HID and drag cases all hit `cellsMatching: 1`, with the centre cell matching the expected pixel. Real HID `CGEvent` moves are used (:121-127).
- The shipped binary is checked for E2E strings and symbols (dmg.yml). Hardened Runtime is verified. Paired legacy/optimized renders are `pixelEquivalent: true`.
- Nothing is mocked silently: when the test falls back to a fixture, it's recorded as unverifiable, not passed.

## Proxy vs proof

| Claim | What is actually proven | Proxy / gap |
|---|---|---|
| Clipboard holds the final processed image | Exact px size, PNG==TIFF==saved file, annotation pixels present, one item, sentinel replaced (E2E.swift:218-247) | Synthetic display frame, not a native one; no color-space/ICC/P3 check; DPI not asserted except retina test |
| Loupe 20/20 reopen | Correct pixels under the cursor in an SCK capture of a test-built overlay | Skips hotkey→Coordinator→OverlayController; test calls syncMouse itself (E2ELoupe.swift:95); same process; 1 screen; 1x; fixed points; app inactive; 20/20 ≈ <14% failure bound |
| Loupe tracks the cursor | 2 HID moves and 6 `w.sendEvent` moves, each checked by pixels | Not a continuous track; no frame-pacing check |
| Perf | Function wall/CPU ms; onScreen ms locked to 60Hz vsync | Not M5 Pro, not 120Hz, not macOS 27; n=5–12; 1 run; blur onScreen p95 29–50 ms |

## Untested and it matters on macOS 27 / M5 Pro / 120Hz
- The Screen Recording permission flow on first run, after denial and after revoking mid-session (CI forces the grant through TCC.db). On macOS 15+ the system shows recurring "allow screen recording" re-prompts (UNVERIFIED for 27).
- Loupe frame pacing on ProMotion: 8.33 ms budget, variable refresh, whether CADisplayLink is used.
- Multiple displays with mixed 1x/2x and 60/120Hz; a loupe crossing displays; stitching.
- Display P3 / HDR (XDR) content in the clipboard and in what the loupe shows.
- Spaces, fullscreen apps, Stage Manager, the notch / menu-bar safe area.
- Windows marked as not shareable, and DRM / secure-input exclusion.
- Memory growth over hundreds of captures (no leak test found).
- macOS 27 SDK and API behavior: CI uses Xcode 16 on macOS 15.8.2, so deprecations aren't tested (UNVERIFIED).
- Notarized distribution: none exists.

## What flips me to SIGN for release
1. One run on real Apple Silicon at 2x/120Hz (ideally macOS 27) of: e2e with a native textured display (no fixture), the loupe checks with `actualBackingScale: 2`, and perf with onScreen p95 ≤ 8.33 ms for pen/rect/hover and the blur numbers stated.
2. A loupe reopen test that runs through the real `coord.capture(.region)` path, with no test-side `syncMouse`. At least 100 trials across fresh launches, with the app both active and inactive.
3. A clipboard test that asserts the ICC/color space on a P3 source.
4. A manual or scripted TCC first-run, deny and revoke pass with recorded behavior.
5. A two-display (mixed scale) result that isn't `unverifiable`.
