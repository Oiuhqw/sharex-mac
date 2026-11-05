> Historical review of an earlier revision. See [the review index](README.md) for current evidence and validation status.

# Perf pass (+ security hardening)

CI: GitHub `macos-15` runner, which has a 1x display. The 2x case is simulated with a synthetic 3456×2234 px frame (16" MBP at 2x).
Frame time = main-thread `sendEvent` + `displayIfNeeded` + `CATransaction.flush` per synthetic event (`App/Sources/E2EPerf.swift`).
Signposts: `App/Sources/Perf.swift:6` (Points of Interest: `shareable-content`, `deliver`, `clipboard-ready`, …).

- BEFORE: https://github.com/Oiuhqw/sharex-mac/actions/runs/41628832920
- AFTER (final): https://github.com/Oiuhqw/sharex-mac/actions/runs/41636884082. E2E 50 results: 49 pass (incl. onscreen-orientation) + 1 unverifiable (multi-display; the runner has one screen). 59/59 Linux `swift test` pass.

| metric (ms, p50 / p95) | target | BEFORE | AFTER |
|---|---|---|---|
| hover move @2x | <8 | 8.84 / 32.58 | **0.10 / 0.20** |
| region drag @2x | <8 | 4.80 / 16.50 | **0.15 / 0.25** |
| overlay build → first frame @2x | | 23.74 / 24.61 | **14.08 / 16.13** |
| hotkey/capture → overlay shown (runner) | <150 | 24.0 / 24.4 | 47.2 / 48.9 (within target; run-to-run noise 27–47) |
| rect / pen / highlighter / move-blur drag @2x | <8 | ~3.5 / 16–17 | ~2–3 / 17–18 |
| new blur drag @2x | <8 | 9.6 / 15.1 | 9.6 / 14.3 |
| commit → clipboard, sync path @2x | <300 | 134.9 / 143.2 | 133.2 / 137.2 |
| commit: main-thread time only | | (all ~135 on main) | **20.9 / 21.3** |
| commit: async pipeline → clipboard-ready | <300 | — | 111.7 / 112.0 |
| save PNG @2x | | 63 / 66 | 79 / 80 (bench now encodes PNG+TIFF; the real path reuses those PNG bytes, so the file save costs no second encode) |

## Root causes → fixes
1. **The whole 30 MB frozen frame was redrawn through `draw(_:)` on every mouse move.** The frame now sits as `CALayer.contents` (`App/Sources/EditorLayers.swift:20`). Annotations draw into their own view, which only invalidates the dirty rect of the changed mark, padded by `reach()` (`EditorLayers.swift:37`, `:80`). The dim, outline, handles, crosshair, label and magnifier are CAShapeLayer/CATextLayer chrome changed in one action-free transaction (`EditorLayers.swift:95`). `EditorView.refresh()` (`App/Sources/EditorView.swift:392`) replaces the old needsDisplay path. Hover and region drag went from 33 ms p95 to 0.2 ms.
2. **Blur and pixelate made a new CIContext and recomputed every frame.** There is now one shared Metal-backed CIContext (`App/Sources/Renderer.swift:150-155`). Each committed mark gets one cached patch (`Renderer.swift:123`); only the mark being dragged stays live (`Renderer.swift:18`).
3. **SCShareableContent was fetched synchronously after every hotkey press.** It is now prefetched at launch (`App/Sources/App.swift:59`) and again after each capture, cached with a 60 s TTL, and dropped when screens change (`App/Sources/ScreenCapture.swift:75-93`).
4. **Decorate and PNG/TIFF encode ran on the main thread (~135 ms freeze on commit).** That work now runs in a detached task through nonisolated ImageIO encode (`App/Sources/Export.swift:35`, `:60`, `:74`; `App/Sources/CaptureCoordinator.swift:168-178`). The main thread is busy 21 ms instead of 135 ms. The overlay closes right away and the clipboard is ready about 112 ms later.
5. **Display-link coalescing was not added on purpose.** AppKit already coalesces `needsDisplay` to one pass per frame. The cost was full-screen rasterization, and fix 1 removed it; a CADisplayLink would add latency for no gain.
6. **Tried and reverted:** a tiled 256 pt annotation surface and a half-resolution live blur, both meant to cut the remaining ~17 ms p95 spikes on annotation drags. CI measured them slower (rect p50 3.4→5.6 ms, new-blur p95 15→36 ms), so both were reverted. Those spikes are probably the 1x software-composited runner copying a large backing store. Apple silicon's GPU compositor needs on-device confirmation.

## Security (from reviews/security-breakdown.md)
1. **Hardened runtime and signing.** `.github/workflows/dmg.yml` no longer sets `ENABLE_HARDENED_RUNTIME=NO`. It signs ad-hoc, inside-out, with no `--deep` and with `--options runtime` (`dmg.yml:42`, `:44`). It asserts the `runtime` flag in `codesign -dv --verbose=4` (`dmg.yml:47`), smoke-launches the app, and publishes `ShareX.dmg.sha256` as an artifact (`dmg.yml:64`, `:70`). A quarantine-simulated install probe runs after the upload with timeouts (non-blocking). **No Developer ID and no notarization**, because the user has no paid Apple account. Gatekeeper therefore asks for "Open Anyway" or `xattr -dr com.apple.quarantine`, as documented in README "Installing the DMG".
2. **E2E code is compiled out of shipped builds.** All E2E and E2EPerf code sits behind `#if SHAREX_E2E` (`App/Sources/E2E.swift:2`, `E2EPerf.swift:2`, `App.swift:10`, `:60`, `ScreenCapture.swift:44`, `:142`, `OverlayController.swift:34`, `CaptureCoordinator.swift:153`). Only the CI test builds set it (`.github/workflows/macos.yml:51`, `:78`). The DMG build fails if `strings` finds `--e2e` (`dmg.yml:32`).
3. **Supply chain.** Actions are pinned to commit SHAs. `permissions: contents: read` is set (`macos.yml:8`, `dmg.yml:5`). XcodeGen 2.46.0 is pinned by sha256 (`scripts/ci-setup.sh:7-8`). `Package.resolved` is committed, and builds use `-disableAutomaticPackageResolution` (`macos.yml:49`, `dmg.yml:23`).
4. **Save folder handling.** The folder is resolved with `resolvingSymlinksInPath` and must be a writable directory (`App/Sources/Export.swift:108`, `:121`). Files are created exclusively with `.withoutOverwriting` (`Export.swift:126-135`). Settings warns about an invalid folder (`App/Sources/SettingsView.swift:50`). `NSLog` is replaced with `os.Logger` (`Export.swift:7`), and paths are logged with `privacy: .private` (`Export.swift:130`, `:137`, `CaptureCoordinator.swift:178`).
5. **Overlay hidden from screen capture.** The overlay window sets `sharingType = .none` (`App/Sources/OverlayController.swift:127`), and E2E still passes (49 pass + 1 unverifiable multi-display). No TransientType or ConcealedType is set, so clipboard managers still see screenshots.

## What CI can't measure
- **ProMotion at 120 Hz** (8.3 ms budget) and real 2x Retina compositing. The runner is 1x and has no GPU compositor, so 2x is simulated in software.
- **macOS 27 and M5 Pro.** The runner is macOS 15.
- **Multiple displays.** The runner has one screen; `multi-display` reports FAIL with `screens: 1` in both BEFORE and AFTER.
- **Window-server compositing time** and real SCK capture latency on a busy desktop.
- **The layer orientation pixel check** (`layerOrientation.ok=false`, 214 vs 228) is inconclusive on the runner and is informational only. The E2E visual tests that pass cover orientation.
To confirm on-device, open Instruments → Points of Interest on subsystem `com.sharexmac.ShareX`.
