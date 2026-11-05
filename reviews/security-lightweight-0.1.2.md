# Security, resource use, and settings review

Status at `e8f9596`: native validation passed on Intel and Apple silicon. Each architecture passed 416 E2E checks with zero failures and six explicitly unverifiable hardware-dependent checks. The [completed source security audit](security-audit-2026-11-05/REPORT.md) covers `e8f9596` with 47 units, 85 checks, 88 source paths, and no confirmed vulnerability. This report is not a security certification or a completed full fuzz campaign.

The goal is a lightweight native macOS screenshot tool with precise selection, annotation, clipboard and local output, and configurable shortcuts. The app uses AppKit, SwiftUI for Settings, CoreGraphics/CoreImage, and ScreenCaptureKit. It has one external runtime package. This is an appropriate foundation for that scope. Native measurements support a small package and low idle footprint, with the workload limits below.

## Scope and revisions

- Main was `6960c15dd550fa4b6681277c8ca6a269f597d809`, equal to origin/main.
- The implementation starts from `48b1ba1bdfe6058f04d62b87dd7f328ee51b2f81`, the existing PR1/PR2 candidate. Its export recovery, fail-closed redaction, crop crossing, and overlay keyboard fixes are retained.
- The fully validated checkpoint is `e8f95968852fc85900f98e6f966d348935f35192` on `codex/security-lightweight-review`. Both native runs passed, including universal packaging.
- Post-audit implementation checkpoint is `1e893fd3993d872fe8736710778eaf78d01021fe`. It combines Last Region recovery, shortcut recovery and conflict handling, the AX read correction, and ellipse hit testing. Integrated native validation is pending.
- E2E, package, idle and hover measurements below refer to `e8f9596`. The separate detailed memory diagnosis refers to `d7e4810550a64862fa6bd555ef27b3929a9f17b9`. Changes from `d7e4810` through `e8f9596` affect the test driver, not production behavior. Subsequent Last Region and shortcut recovery changes modify production behavior and require separate validation.
- Source assessment covered all 22 production Swift files, the core model, capture/export boundaries, stored preferences, release workflows, and the pinned runtime dependency.
- Production inputs are OS display/window pixels and metadata, local preferences, and user editor actions. No upload client, network listener, or imported-image parser was found in production source.

## Findings addressed in source

| Finding | Change | Verification added |
| --- | --- | --- |
| A later blur or pixelation could replace earlier protected pixels with a weaker effect computed from the original screenshot. | Preserve earlier protection. Replace its pixels with opaque black in later filter inputs. Clip later output outside earlier coverage. Update dependent caches when geometry or order changes. | Paired source images that differ only under protection, overlapping masks, dirty redraws, mutation/undo, and live/export comparisons at 1x and 2x. |
| Effect images could accumulate without a byte bound. A live layer could retain its last image. | Limit committed patches to 64 MiB and 128 entries. Limit the cached live effect preview to 16 MiB. Release image contents, callbacks, and caches at session close. | Entry and byte eviction, repeated output comparison, weak ownership checks, post-commit live-image checks, and repeated capture/edit/export sessions. |
| Image dimensions were checked without a sufficient total allocation bound. | Check pixel-area arithmetic before capture, contexts, stitching, canvas padding, and decoration. Validate returned image storage. Refuse output that exceeds 64 Mi pixels. | Overflow, non-finite dimension, oversized area, and decoration refusal cases that avoid huge test allocations. |
| Stored preferences could be parsed without a byte limit, and a malformed last region could reach capture geometry. | Bound stored settings to 1 MiB before parsing. Reject an invalid last region without losing other valid preferences. | Settings boundary and preference-preservation regressions. |
| A comment implied that other recording apps could not capture the editor. | Remove the guarantee and document the platform limitation. The app's own ScreenCaptureKit filter still excludes its process. | Source review against Apple's window-sharing documentation. |
| Precision and settings controls were incomplete for the requested workflow. | Use crop dimensions in image pixels for labels, support one-pixel crop movement/resizing, suppress the source loupe over protected content, and add native settings pages with searchable shortcuts. | Native event-driven crop, settings, recorder, persistence, folder, clipboard, and capture checks. |

Blur and pixelation obscure content; they do not guarantee that sensitive text is unrecoverable. Use a fully opaque filled rectangle for complete concealment. Other recording or screen-sharing apps may capture the frozen editor before redaction is finished. Apple's [window sharing documentation](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none) describes the legacy sharing setting.

## Post-audit correctness review

The full source audit stays pinned to `e8f9596`. The [independent follow-up](security-audit-2026-11-05/FOLLOW-UP.md) checks 11 changed source, test, and script paths at `acfa92f`, with ten source checks mapped to 20 existing coverage IDs. It found no qualifying security candidate or source blocker.

- Last Region now requires its saved display ID. If that display is absent, capture requests a new region selection. The focused native run [42020909475](https://github.com/Oiuhqw/sharex-mac/actions/runs/42020909475) passed 418 E2E checks with no failures and six unverifiable checks.
- Shortcut registration checks the eight owned preferences before the dependency reads them. Encoded values have a 1 KiB limit and must fit native integer widths. Valid custom strings, disabled assignments, and unrelated preferences remain unchanged.
- Independent review found that restoring a damaged preference could duplicate a valid custom shortcut. Recovery now uses the same conflict lookup as the editor. It leaves a conflicting recovered default explicitly disabled, including after another launch. The added native checks require the actual Region action and no unintended clipboard or file output.
- Final independent review found that a flat ellipse with a thick outline could paint pixels outside its selectable area. Hit testing now uses a portable edge-distance calculation with a bounding-box rejection and at most 64 bisections. Ten core tests and two native pixel, selection, and deletion scenarios cover the correction. This path runs on clicks, not pointer-only hover.
- The test driver retries only failed Accessibility reads within its original three-second operation deadline. It does not repeat actions or relax final-state checks. The earlier failure came from two read errors before mutations. The cause of the macOS messaging delay is unproven. Apple documents these messaging failures in [AXUIElement.h](https://developer.apple.com/documentation/applicationservices/axuielement_h).

The first integrated `acfa92f` runs passed all 63 shortcut recovery checks on both architectures. Normal E2E recorded 418 passes, two failures in the new ellipse snapshot checks, and six unverifiable checks. Selection, deletion, and restored export passed. The snapshot omitted the frame background, leaving transparent pixels where the test expected white. The failures remain recorded. A separately reviewed test-only correction now shares one isolated-layer compositor across the privacy, redaction, and ellipse suites. It removes both old helpers and requires opaque background pixels before checking ellipse deletion. This models separate layer backing bitmaps as described in Apple's [Core Animation guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/SettingUpLayerObjects/SettingUpLayerObjects.html); it does not prove physical compositor behavior. Fresh integrated native runs remain required. The historical measurements below remain tied to their stated revisions.

## Settings and dependencies

Capture, Shortcuts, and Output pages provide eight capture commands, search, native shortcut recording, duplicate feedback, clear, per-command defaults, restore-all confirmation, and a native directory picker. A new installation copies to the clipboard and saves a PNG in `~/Pictures/ShareX`. A stored preference that disables local copies remains disabled.

KeyboardShortcuts is upgraded from 2.3.0 to 3.1.0 at `772133d9dbe800fdac0473226822994c5c162c58`. The package remains the only external runtime dependency and declares no transitive packages. Its upstream recorder fixes are documented in [issue 241](https://github.com/sindresorhus/KeyboardShortcuts/issues/241). The pinned manifest requires Swift 6.2, so CI selects Xcode 26.3. The deployment minimum remains macOS 14.

The OSV query for `SwiftURL/github.com/sindresorhus/KeyboardShortcuts` version 3.1.0 returned no advisories on 2026-11-04. The repository's public GitHub advisory endpoint also returned an empty list. These are database results, not proof that the package has no defects.

## Validation evidence

| Check | Current result |
| --- | --- |
| Portable script and metric-validator tests | 26 passed on Windows, using explicitly selected Git Bash for stubbed shell checks. No WSL. |
| Whitespace and source encoding | `git diff --check` passed. All 49 Swift files, including the two existing standalone fuzz targets, decoded as UTF-8. |
| Core suite | 85 tests passed on Intel and Apple silicon at `e8f9596`. |
| Core suite with AddressSanitizer | 85 tests passed with a second fixed seed for the existing property tests. |
| Native build and launch | Debug and Release builds passed; the app stayed alive for the 10-second smoke check. |
| App E2E and settings screenshots | [Intel run 41903672805](https://github.com/Oiuhqw/sharex-mac/actions/runs/41903672805) and [Apple silicon run 41905149760](https://github.com/Oiuhqw/sharex-mac/actions/runs/41905149760) each passed 416 checks, with zero failures and six unverifiable checks. Recording, duplicate, clear, default, reset, search, folder selection, fresh-process persistence, and capture with the recorded shortcut passed. Settings screenshots were inspected. |
| Release timing and resource measurements | Both successful runs passed 28 timing series, six paired renderer cases, and two resource scenarios. Hover main-thread CPU p95 was 0.971 ms on Intel and 1.581 ms on Apple silicon, below the unchanged 2 ms gate. Each measured 60 events and verified the intended hover work. |
| Universal DMG, test-code exclusion, signature and install checks | Both native runs passed packaging. The Intel run produced a 1,928,816-byte DMG (1.84 MiB); the app occupies 4,576 KiB. Five warm-idle samples before capture measured 27,368 to 27,400 KiB RSS, with a median of 26.73 MiB. |

The first Apple silicon run at the same source revision, [41903672031](https://github.com/Oiuhqw/sharex-mac/actions/runs/41903672031), passed all 416 E2E checks but failed the hover CPU p95 gate at 2.236 ms. The runner reported load 25.23 across three logical CPUs. One repeat passed without code or threshold changes. This is retained measurement variance, not proof of a regression or a fix. Neither CPU timing nor hosted display callbacks measure physical screen presentation.

The six unverifiable checks cover a textured native desktop fixture, four physical 2x compositor comparisons on a 1x hosted display, and multi-display behavior on a single-display runner. Synthetic 2x coverage remains separately labelled. The DMG SHA-256 is `50c81cff052315aaf91e46f27b23b033acb4553b4cacb1c08fcc3912922b7cbf` and was checked against the downloaded file.

The resource driver records five measured sessions and five warm-idle samples for each of a synthetic 2x display and the runner display. It checks successful PNG output, editor/renderer release, live-layer release, cache limits, and no document synchronization on pointer-only movement. It records current RSS, process lifetime peak RSS, process user/system CPU, and runner load. Display fixtures are labelled separately from ScreenCaptureKit capture.

The buffer limits do not cap total process RSS. Measurements include framework caches and PNG validation work, and exclude WindowServer/GPU use. In a separate five-session diagnostic, all tracked image providers and editor owners released on both architectures. Intel RSS rose from 134.8 to 317.1 MiB. Apple Silicon RSS rose from 164.4 to 335.7 MiB before the first profiler sample, then fell to 277.6 MiB before any cache clear. A test-only Core Image cache clear produced no immediate or settled RSS reduction on either architecture.

Before the clear, `vmmap` reported physical footprint as `39.5M` on Intel and `33.3M` on Apple Silicon, using its printed units. It classified substantial resident memory as reusable allocator storage. This supports reusable memory as a contributor to RSS growth. The tracked original screenshot providers and editor objects had released. The measurements do not account for every framework copy or prove bounded memory over a long session. No production cache purge was added. Regular and diagnostic workloads have different RSS results and must not be combined into one measurement.

The package's five idle CPU samples displayed 1.2% followed by four 0.0% values. Cumulative CPU time changed from 0.28 to 0.29 seconds. The percentage is a decaying process average, not a precise five-second interval measurement. Hosted display-link callbacks measure the next callback, not physical screen presentation.

GitHub reported an [Actions incident](https://www.githubstatus.com/incidents/xr3myzj7ms51) while the baseline and integrated jobs were queued. The [baseline](https://github.com/Oiuhqw/sharex-mac/actions/runs/41862938601) ended with zero executed steps after hosted runner acquisition failed, with arm64 capacity notices. An explicit Intel dispatch started successfully. Queue or infrastructure failure is not an application test result.

## Independent review and remaining work

Three independent reviews used GPT-6 Astra for Settings, renderer, and validation. A further integration and trail review used GPT-6.1 Sol. Confirmed findings led to bounded dependency scans, consistent pixel rounding, a corrected test-only CoreFoundation cast, a simpler process RSS query, and stronger test assertions. Folder acceptance must change the saved path. A shortcut timeout fails when synthetic event posting is permitted. Live-image checks require an image before release. Nine added narration comments were removed; no comment HOLD remains.

Native fractional CoreGraphics coverage, source-scale privacy, and actual editor drag/commit checks passed. Native compositor comparisons allow one RGB level of color conversion difference and require exact alpha. Source-scale comparisons remain exact. Four 2x compositor checks on a 1x display remain explicitly unverifiable. A layer snapshot does not prove the absence of a transient frame on physical hardware.

The full delegated fuzzing job was rejected by an automatic safety check for possible cybersecurity risk before producing results. It was stopped and not rerouted. The existing seeded property tests and normal AddressSanitizer suite are narrower checks. Do not describe them as a full fuzz campaign.

The source audit is complete. It produced 17 hardening and correctness notes covering 16 topics. Last Region display recovery and malformed shortcut preferences received focused follow-up changes. These are reliability improvements, not confirmed cross-boundary vulnerabilities. The remaining notes retain their stated prerequisites and limits in the audit report. Final integrated native checks and merge verification remain pending. A hosted runner cannot certify physical keyboard use, interactive permission prompts, or real mixed Retina/multi-display hardware. Synthetic geometry tests must stay labelled as such. The app remains ad-hoc signed and is not Apple-notarized.

The test-only Settings driver uses a separate accessibility helper to avoid querying SwiftUI from the same process during layout. It limits the target to its parent process, uses a three-second operation deadline and a five-second process watchdog, and bounds its input, output, and tree traversal. It verifies focus, real menu and sheet closure, and resulting stored state. The helper and all E2E code are excluded from the shipped app.

The picker exposes the fixture filename as an accessibility text field inside a group and list. Revision `db35dac` recognized that item but traversed ancestor directory columns first and exhausted its deadline. Revision `e8f9596` visits the current column first and the first sorted list entries first. An independent replay of the recorded tree reached the target at visit 32 instead of visit 209. The test still requires the exact selected URL before Choose and matching returned, live, and freshly loaded paths afterward.

The shortcut test now observes the pinned library's recorder completion before sending one HID key pair. It also records whether capture accepted the request, using the existing capture-start stamp. Source review found a real readiness gap in the old test, but the saved Intel artifact does not prove that this gap caused its failure. The capture timeout and failure classification remain strict. This check passed on both architectures at `e8f9596`.
