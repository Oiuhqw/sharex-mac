# Capture and editor improvement verification

The goal is to make screenshot selection, annotation, repair, saving, and completion feedback clearer. All five requested feature groups are implemented. The full native validation workflow passed on 12 November 2026.

## Implemented behavior

| Area | User-visible result | Implementation |
| --- | --- | --- |
| Crosshair magnifier | Circular pixel loupe with a matching rim, center marker, and coordinate badge. | Existing nearest-neighbor pixel sampling and protected-area suppression remain in place. |
| Style feedback | Selected color, numeric values, checkerboard preview, immediate canvas updates, and Reset tool style. | One style mutation path and a typed gesture retain the target and before-state. One slider drag creates one undo entry. |
| Smart Eraser | Local repair of small objects on plain areas and smooth gradients. Move, resize, undo, redo, and export work together. | A robust RGB background fit reads at most 512 ring samples and produces a fixed 32 by 32 patch. It excludes the erased interior, protected content, transparent pixels, and display gaps. |
| Saving | PNG saving stays enabled for new and legacy settings. The toolbar states the output destination. | Explicit opt-outs remain effective. Each capture retains its promised output settings, including through window selection. |
| Capture sound | A short shutter click with a preview in Output settings. | A generated 90 ms WAV plays after all requested outputs succeed. The mute preference and partial-output recovery remain effective. |
| Additional polish | Tool-specific controls, stable toolbar buttons, and usable canvas space around small or tall images. | The toolbar and canvas use the same row calculation. Pixel rounding is included in the screen fit. Export retains the source resolution. |

Smart Eraser is intended for screenshot backgrounds. It does not provide general photo reconstruction. An unsuitable or unsafe repair stays covered and gives recovery guidance. The image never leaves the app for repair.

## Native validation

Tested source revision is `599e46e5870e17e0f46cc59add149de152f7aecb`. The [full macOS run](https://github.com/Oiuhqw/sharex-mac/actions/runs/43168138070) builds Debug and Release and drives the real AppKit app.

| Gate | Result |
| --- | --- |
| Core tests | 117 passed, including 13 new style-gesture cases. |
| AddressSanitizer | The same 117 tests passed under the sanitizer. |
| CI script tests | 26 passed. |
| Native checks | 938 recorded, with 929 passed, zero failures, and 9 explicit unverified instances across 7 labels. |
| Launch at login | Seven registration, relaunch, and opt-out scenarios plus cleanup passed in the full app. |
| Builds and resources | Debug, smoke launch, Release, existing performance limits, and all 6 memory ownership checks passed. |
| Mixed-scale displays | Both horizontal and vertical-negative layouts passed, with 109 recorded checks each. |

All 24 synthetic solid-background and gradient repair cases passed. Their maximum RGB channel error was 1 out of 255, and surrounding pixels were unchanged. These measurements apply to those synthetic fixtures. The generated capture sound decoded as 90 ms and 7,982 bytes.

The nine unverified instances cover two uniform-runner desktop texture checks, four 2x-source/1x-display compositor alignment checks, one single-screen main-suite multi-display check, and two physical-input/separate-Spaces checks. Dedicated virtual-display runs cover the two mixed-scale layouts separately. See the [machine-readable validation summary](capture-polish-evidence/validation.json) and [per-suite results](capture-polish-evidence/checks.json).

The slider checks post real CoreGraphics mouse events. They verify intermediate live and exported pixels, retained focus, one undo entry, redo, a no-op drag, and keyboard changes. Smart Eraser checks cover repair quality, surrounding-pixel equality, protection rules, failed repairs, movement, resize, undo, export, and resource bounds. Canvas checks use native window captures and retain exact source-pixel and output-scale comparisons.

The native campaign found and corrected popover teardown ordering, stale window-picker settings, toolbar overlap, and screen-fit rounding. It also corrected input and pixel-sampling fixtures without lowering the color or export gates. The final tall-canvas sample uses a wider known-color band because the original band minified to about two screen pixels. Edge blending was an inference from the filter and geometry; the old log omitted two channels needed to identify the exact failed predicate.

The focused native probe reproduced a startup test failure at a fresh service's `notFound` state before it attempted registration. The test now reaches the existing registration code and still requires `enabled` afterward. The [corrected native probe](https://github.com/Oiuhqw/sharex-mac/actions/runs/43168057474) passed all seven registration, relaunch, and opt-out scenarios plus cleanup. The probe compiles the actual startup code in a small app bundle. It supplements the full application run. Each startup step now prints its captured result even if it fails.

## Review and cost

Independent reviewers assessed the feature design, implementation, capture settings, native input, canvas layout, and final evidence changes. All accepted correctness findings were fixed. The final GPT-6 Astra review accepted `c38f091..599e46e` with no P1 or P2 findings. It also exercised shell failure paths and inspected the successful native startup probe.

The repository is public. Validation used standard `macos-15`, which GitHub lists as free for public repositories. Artifact uploads and DMG packaging were disabled for these dispatches. Both workflows were restored to their original disabled state. See [GitHub runner pricing](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) and [Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).

## Evidence and limits

The following files were extracted unchanged from the successful native job log.

| Evidence | Source |
| --- | --- |
| [Circular loupe](capture-polish-evidence/round-loupe.png) | Actual magnifier layer rendering. |
| [Editor loupe](capture-polish-evidence/loupe.png) | Native editor fixture capture. |
| [Style controls](capture-polish-evidence/style-feedback.png) | AppKit content-view capture. |
| [Style window](capture-polish-evidence/style-feedback-window.png) | ScreenCaptureKit popover capture. |
| [Smart Eraser comparison](capture-polish-evidence/smart-erase.png) | Source fixture on the left, repaired result on the right. |
| [Tall canvas](capture-polish-evidence/capture-canvas-tall-native-window.png) | ScreenCaptureKit window capture with visible top border and annotation. |
| [Image orientation](capture-polish-evidence/onscreen-orientation.png) | Native editor orientation fixture. |
| [Capture click](capture-polish-evidence/capture-click.wav) | The generated WAV used by the app. |

The Style content image comes from AppKit's actual view drawing and has a transparent background. View it on a light background to read the dark labels. The ScreenCaptureKit popover image is retained separately because the runner scales that window capture unexpectedly. Native mouse, keyboard, focus, and rendered-pixel checks provide the interaction evidence.

Physical display hot-plug, separate Spaces, real mixed-density display capture, and interactive permission prompts still require physical Mac hardware. The virtual-display runs cover both horizontal and vertical layouts with 1x and 2x displays. Performance checks enforce the existing limits; this work makes no speedup claim on the shared runner.

## Decisions that shaped the work

| Principle | Concrete choice |
| --- | --- |
| Experience First | Live style values, visible selection, and preview accompany the controls. |
| Model the Domain | A typed style gesture owns its target and before-state. |
| Foundational Thinking | Repair uses bounded local samples and a fixed-size patch. |
| Laziness Protocol | Existing save defaults and output recovery remain the authoritative paths. |
| Separate Before Serializing Shared State | Implementation workers used separate Git worktrees. |
| Sequence Work into Verifiable Units | Each coherent improvement and correction has a checkpoint commit. |
| Attack the Premise | Native HID delivery replaced a synthetic event fixture that did not reproduce slider tracking. |
| Test Behavior, Not Implementation | Assertions check visible pixels, output files, clipboard content, focus, and undo behavior. |
| Explain the Number | Performance results include runner context and support only the existing regression gates. |
| Build the Lever | A small native startup probe exposes OS registration results without rebuilding the whole app. |
| Prove It Works | Native E2E, real capture artifacts, and independent review gate completion. |
| Never Block on the Human | Reversible implementation and review continued while native execution was arranged. |

Next, review the pull request and merge it when accepted. A release package and physical Mac checks can follow. This work does not merge the branch or publish a release.
