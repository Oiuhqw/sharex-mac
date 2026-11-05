# Multi-display capture and release validation for 0.1.3

Version 0.1.3, build 4 keeps fullscreen editing on the original displays and permits region selection across display boundaries. A fixed top toolbar provides mouse access to capture tools, styles, history, completion, and cancellation. New installations assign only Control-Shift-1 for Region.

The app supports macOS 14 or later on Apple Silicon. Intel Macs are unsupported. This assessment covers the multi-display change and its native validation. It does not claim a new complete source security audit.

## Validation identity and results

The diagnostic source is `d1da11ae7703d43a282cdfc037bc1f1e35e83c1d`. The evidence is in [native run 42095082301](https://github.com/Oiuhqw/sharex-mac/actions/runs/42095082301).

The complete diagnostic workflow passed on 5 November 2026 UTC. It ran on an arm64 host with macOS 15.8.2 (24H232), Xcode 26.3 (17C529), and Apple Swift 6.2.4.

| Suite | Passed | Failed | Unverified |
| --- | ---: | ---: | ---: |
| Script tests | 26 | 0 | 0 |
| Core XCTest | 104 | 0 | 0 |
| Core XCTest with AddressSanitizer | 104 | 0 | 0 |
| Baseline native E2E | 432 | 0 | 6 |
| Shortcut recovery and relaunch | 63 | 0 | 0 |
| Horizontal mixed-scale displays | 94 | 0 | 1 |
| Vertical mixed-scale displays | 94 | 0 | 1 |
| Release native checks | 30 | 0 | 1 |
| Separate memory ownership checks | 6 | 0 | 0 |

The native app suites total 719 passing check executions and nine explicitly unverified cases. All 420 passing baseline checks from the parent remain passing. The strict metrics validator passed 28 timing series, six paired renderer cases, and two resource scenarios. Clipboard, PNG, and asynchronous output each completed five of five operations without errors.

Both display layouts reached the requested 1280 by 800 logical modes at 1x and 2x. Native window, software projection, export, toolbar, Last Region, and cleanup assertions passed. Cleanup recorded zero live objects and a successful complete online-display list containing only the original display. Both created IDs were absent.

The diagnostic ARM64 package passed architecture, icon, test-code exclusion, strict signature, Hardened Runtime launch, DMG verification, and quarantine-simulated installation checks. Its downloaded DMG matched its build checksum. This package validates the diagnostic source; the release notes identify the separate final build from merged main.

The final PR linked from the [0.1.3 release](https://github.com/Oiuhqw/sharex-mac/releases/tag/v0.1.3) records independent review and a separate native run at its exact documentation head. The release notes identify the build from merged main. The diagnostic package is not the final release package because `INSTALL.txt` is included in the DMG.

## Implemented behavior

`EditorSession` owns the document, gesture, history, native text field, renderer, and terminal outcome. Each original display has a panel that projects this state into local coordinates. Cross-display drags remain one gesture. Text commits before a tool command or host change. A display topology change or cancellation ends the session once.

The fixed top toolbar exposes Tool, Style, More, Done, and Cancel on every display. Style includes blur and pixelation strength. More provides Undo, Redo, and Delete selected. Compact controls and the Style popover have explicit outer constraints so their full control frames fit within their containers.

`DesktopImageSource` retains native tiles instead of allocating a desktop-wide bitmap. Export uses the highest scale among displays that intersect the crop. An unrelated Retina display does not increase a small 1x crop's scale. Empty desktop gaps remain transparent. Oversized output disables Done until the user reduces the crop. No silent downsampling occurs.

Effects sample bounded regions across tile seams. Prior protection masks and an opaque matte apply before clamping. Existing pixelation anchoring and opaque failure coverage remain in force. A scale change clears cached effects and protection geometry before all panels redraw.

Last Region stores participating display frames relative to an anchor. It accepts common translation, scale changes, and extra untouched displays. Moved, resized, or missing participants start fresh selection. The coordinator checks geometry after the countdown and again against the returned frozen display subset. Last Region changes only after an output succeeds.

The eight shortcut command names remain stable. New installations assign only Region. Existing valid bindings, old defaults, and explicit disabled values remain unchanged. Restore All clears the other seven factory assignments.

## Native E2E inputs and image evidence

The driver uses two virtual displays with real Core Graphics and `NSScreen` geometry. Each display has 1280 by 800 logical points. One runs at 1x and the other at 2x. The `horizontal` and `vertical-negative` layouts exercise both seam directions and negative origins. `ready.json` and helper logs record actual geometry and selected modes.

Frozen tiles are deterministic image fixtures. This input isolates geometry and rendering from unavailable textured display capture on the hosted runner. It does not claim that ScreenCaptureKit captured those tile pixels from physical displays.

ScreenCaptureKit separately captures actual editor windows. The native PNGs check visible seam projection and effects against expected content. The driver also records software layer images and exported PNGs. Each image path has separate assertions, so a software comparison cannot substitute for a failed native capture.

Native comparisons require at least 16 samples per panel, with at least four near the seam. The RGB-sum tolerance is 0.04 and the alpha tolerance is 0.01. Expected-neighborhood stability filters reject ambiguous sampling positions. Only the actual toolbar and visible crop-size label rectangles are excluded as UI. Logs retain geometry, tested and skipped counts, and first mismatch values.

The software snapshot uses nearest interpolation only when FrameView's native layer uses nearest filters. Annotation layers retain their own settings. Strict software samples and thresholds remain unchanged.

The display suites check rectangular selection across the seam in both directions, shared undo, text host changes, toolbar and Style containment, fullscreen panels, sparse crops, and cache invalidation.

The baseline and Release regression fixture checks both rectangular and freehand selection across two native windows on one display. Its synthetic two-tile layout includes a nonzero viewport origin. It checks gesture coordinates, selection projection, native window pixels, output pixels, and compact control transitions. This is separate from the real mixed-scale virtual-display layouts.

Posted AppKit mouse events must produce Done or Cancel before cleanup, with exactly one terminal outcome. This is native app-event evidence, not physical mouse routing evidence. Freehand routing across physical mixed-scale displays remains a hardware check.

Clipboard and PNG checks inspect actual delivered images, including dimensions, color samples, seam content, and participant-only Last Region output. Countdown and post-freeze mutations record immutable anchor geometry, actual topology, and timing. Invalid saved geometry must start fresh selection instead of producing a stale capture.

The external helper owns the private virtual-display APIs. Teardown requires zero live display objects and successful online-display enumeration with both created IDs absent. The three-second removal deadline and failure propagation remain mandatory. Invalid-ID scalar queries are diagnostic only.

## Resource and performance gates

The strict validator checks 28 timing series, six paired renderer cases, and two resource scenarios. It rejects missing measurements and failed output operations. Repeated sessions check delivered output, retained buffers, and released ownership. Clipboard, PNG, and asynchronous pipeline operations must finish successfully.

The Release hover gate requires p95 main-thread CPU below 2 ms and verifies that events update the magnifier. Debug elapsed time, Release wall time, and display-link callbacks remain diagnostic. Hosted-runner callbacks do not measure physical presentation time. This assessment makes no relative speedup claim.

Images are limited to 64 Mi pixels, and effect source samples are limited to 16 Mi pixels. The effect cache retains at most 64 MiB across 128 entries. The live effect preview retains at most 16 MiB. These limits do not cap process RSS. Resource results distinguish current RSS, peak RSS, idle CPU, and object release. A separate Release process checks image-provider lifetime and context caches.

## Build and package evidence

CI uses the Apple Silicon `macos-15` runner and selects Xcode 26.3. The result record above states the actual OS build and Swift version. Debug, Release test, and packaged executables must contain exactly arm64.

The core workflow runs deterministic property tests with `FUZZ_SCALE=1`. The normal seed is `1525137630`, and the AddressSanitizer seed is `3405691582`. These are bounded deterministic runs. They do not complete the historical full fuzz campaign.

The package workflow builds without `SHAREX_E2E`, checks the icon, and scans the executable and symbols for test code. It also rejects private virtual-display API references and helper files. The packaged app is ad-hoc signed with Hardened Runtime. Signature checks, direct launch, DMG verification, and a quarantine-simulated installation are separate gates.

Ad-hoc signing is not notarization. Gatekeeper may block a downloaded copy. The installation smoke check includes launch after quarantine removal. It does not certify the interactive Gatekeeper or Screen Recording flow on a clean physical Mac. Developer ID signing and notarization require the owner's Apple credentials.

Download `ShareX.dmg`, `ShareX.dmg.sha256`, and `INSTALL.txt` from the [same release](https://github.com/Oiuhqw/sharex-mac/releases/tag/v0.1.3). Its attached checksum identifies the published file. The release record supplies the merged source, package run, and final package metadata.

## Independent review scope

Independent source review covers the change from main base `a5836fb04e83a70a59d7d527bd0729ca7c9fce5f` through the diagnostic checkpoint. The review includes shared ownership, event coordinates, bounded rendering, redaction failure coverage, Last Region revalidation, shortcut migration, native probes, and test-helper teardown.

The review distinguishes production defects from invalid test probes. Earlier native rounds exposed compact control overflow, software layer-coordinate errors, sampling differences, and helper teardown detection errors. Those rounds remain failed evidence at their own revisions. They do not count as passing results for this checkpoint.

The final PR provides the independent verdict at its exact final head, including the documentation changes. The merged-main build provides separate final package evidence. Source review, a diagnostic run, final-head validation, and the published artifact each have their own identity.

## Unverified cases and security limits

The baseline result file reports its own unverified cases. Hosted-runner limits include unavailable textured native display pixels, four physical Retina compositor cases, and the absent second display during the baseline suite. Dedicated virtual-display checks supply separate geometry coverage. They do not convert those baseline hardware cases into passes.

Each dedicated layout separately records physical mouse routing and separate Spaces as unverified. The Release result file separately records its native display texture limit. Unverified results are excluded from passing-check totals.

Physical display hot-plug, real mixed-density display capture, interactive permission prompts, and physical shortcut use remain unverified. These are evidence limits, not observed product defects. The frozen-image workflow and adjustable blur strength are intended behavior.

Blur and pixelation do not guarantee that sensitive content cannot be inferred. A fully opaque filled rectangle covers that content in the exported image. Other recording apps may capture the editor before the user finishes redaction.

The [47-unit source security audit](security-audit-2026-11-05/REPORT.md) covers `e8f9596`. The [0.1.2 assessment](security-lightweight-0.1.2.md) and later historical source reviews retain their own revision scope. None certifies the complete 0.1.3 patch. The full fuzz campaign remains incomplete.

## Reproduce the checks

The workflow's result artifacts are the source for the exact totals above. On the configured Apple Silicon runner, the main commands are:

```sh
python3 -m unittest discover -s scripts/tests -v
FUZZ_SEED=1525137630 FUZZ_SCALE=1 swift test --package-path Packages/ShareXCore --parallel
FUZZ_SEED=3405691582 FUZZ_SCALE=1 swift test --package-path Packages/ShareXCore --sanitize=address --parallel
scripts/e2e.sh
scripts/e2e-multidisplay.sh
scripts/perf.sh
python3 scripts/validate-perf.py perf-out/perf.json
```

The app builds, permission setup, separate memory-diagnosis process, and package checks are defined in [the macOS workflow](../.github/workflows/macos.yml) and [the DMG workflow](../.github/workflows/dmg.yml). `scripts/e2e-multidisplay.sh` requires the GitHub macOS runner environment and an existing Debug E2E build. Windows static checks do not replace native execution.
