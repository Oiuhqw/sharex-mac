# ShareX macOS — final pre-release defensive security review

Read-only static review. No source edited, nothing built or run, no PR comments. Repo text treated as untrusted data.

## Verdict: SIGN

No release blocker found. Every hard gate the brief named is now met in source:
- Redaction replaces pixels in the flattened bitmap and fails closed to an opaque black fill.
- All E2E/test hooks are compiled out of Release (`SHAREX_E2E`) and the DMG job fails if any `--e2e` string or E2E symbol is in the shipped binary.
- Hardened Runtime is on in the shipped build, and CI asserts the `runtime` flag.

**Posture choice to accept, not a defect:** the DMG is ad-hoc signed and not notarized because there's no paid Apple account (dmg.yml:1-2, 57-63). Gatekeeper blocks first launch, and the Screen Recording grant resets on every new build. That's acceptable for a free GitHub release if the README says so. It's covered by an install note and a published `ShareX.dmg.sha256` (dmg.yml:80-87).

Fix before or soon after release (not blockers): N1 (redaction strength floor too low), F6 (clipboard TransientType still missing), N2 (Save As writes with `.atomic`, which replaces the file the user picked; that's expected) and the F8 leftovers.

## Prior audit F1–F13

| # | Prior | Status | Evidence |
|---|---|---|---|
| F1 Hardened Runtime off in DMG | High | **FIXED** | dmg.yml no longer sets `ENABLE_HARDENED_RUNTIME=NO`. Signing goes inside-out with `codesign --force --options runtime` and no `--deep` (dmg.yml:51-60). Asserted at dmg.yml:62. project.yml:45 is `YES`. |
| F2 Ad-hoc, not notarized, checksum unpublished | Med | **PARTLY FIXED / accepted posture** | Still ad-hoc with `--sign -`, `--timestamp=none` and no notarytool (dmg.yml:57-59). The checksum is now written and uploaded as an artifact (dmg.yml:80, 81-87). UNVERIFIED: whether the release page attaches `.sha256` (there's no release-publish job; the artifact is only a workflow artifact). |
| F3 E2E hooks in Release | Med | **FIXED** | Every E2E*.swift file is wrapped in `#if SHAREX_E2E … #endif` (line 1/2 to EOF). Seams are gated in App.swift:10-12,60-62; ScreenCapture.swift:44-56 (Release gets `let … = nil/false` constants); Export.swift:15-18,86-88,104-106; Renderer.swift:24-28,67-79,213-215; ExportDelivery.swift:63,90,109,122; CaptureCoordinator.swift:153-155 (`suppressAlerts`); OverlayController.swift:34-36. The flag is only added by CI command-line overrides (macos.yml:169,196), not in project.yml. dmg.yml:21-27 builds without it, and dmg.yml:31-40 fails on `--e2e` strings or E2E symbols. `Perf.swift` stays ungated but only records signposts and timestamps: no args, no I/O. UNVERIFIED: the strings/nm gate hasn't been seen to pass on a real build here. |
| F4 Actions unpinned / no permissions / brew xcodegen | Med | **FIXED** | checkout pinned to `34e1148…` (v4.3.1) and upload-artifact to `ea165f8…` (v4.6.2) (dmg.yml:14,81; macos.yml:20,89,97,105). `permissions: contents: read` (dmg.yml:7-8; macos.yml:8-9). XcodeGen 2.46.0 is fetched and checked against SHA-256 (scripts/ci-setup.sh). |
| F5 No Package.resolved | Med | **FIXED** | Package.resolved is committed and pins KeyboardShortcuts 2.3.0 at revision `045cf174010beb335fa1d2567d18c057b8787165`. ci-setup.sh copies it into the generated project, and the builds use `-disableAutomaticPackageResolution`. UNVERIFIED: that this revision is the upstream 2.3.0 tag. |
| F6 Clipboard TransientType/Concealed | Low | **STILL OPEN** | Export.swift:89-93 writes only `.png` and `.tiff`. Neither marker type appears anywhere in the repo. |
| F7 Save path | Low | **FIXED** | `resolveFolder` (Export.swift:125-143) trims and tilde-expands the path, rejects non-absolute paths, resolves symlinks, standardizes, and requires an existing writable directory. `writePNG` uses `.withoutOverwriting` (O_EXCL) and retries on `fileWriteFileExists` (Export.swift:147-159). `savePNG` now reuses `writePNG` (line 119-121). A symlinked *folder* is still followed by design, which is fine. Settings still use a free-text field (SettingsView.swift:49), but invalid input gets flagged (line 50). |
| F8 Settings decode bounds | Low | **STILL OPEN (minor)** | `saveFolder` has no length or control-character cap (Settings.swift:54). `lastRegion` isn't validated on decode (line 52), but it's still clamped in `resolve` (line 16-19), and `resolveFolder` rejects a bad path at use. Decoding is crash-hardened by JSONSerialization prevalidation (line 36-41). |
| F9 NSLog paths without privacy | Low | **FIXED** | Production code uses `os.Logger` with `privacy: .private` for paths (Export.swift:149,156). The only remaining NSLog calls are in E2E files compiled out of Release. |
| F10 Overlay sharingType | Low | **FIXED** | `w.sharingType = .none` is set for every overlay and editor surface (OverlayController.swift:131) and the countdown (Countdown.swift:20). UNVERIFIED: how ScreenCaptureKit on macOS 15 honours `.none`. |
| F11 Entitlements | Info | **UNCHANGED (good)** | There's still no .entitlements file, so there are no library-validation, DYLD, get-task-allow or JIT exceptions. UNVERIFIED: the embedded entitlements of the built DMG. |
| F12 Temp files | Info | **RESOLVED via F3** | Only E2E/E2EPerf wrote to /tmp, and both are compiled out. The production path has no temp files. CI-only /tmp use (dmg.yml:46,96) is on the runner. |
| F13 CI injection | Info | **UNCHANGED (good)** | No `pull_request_target`, no `github.event.*` in `run:` steps, no secrets. `macos.yml` triggers on `push` and `workflow_dispatch` only. |

## New findings

| # | Sev | file:line | Risk | Fix |
|---|---|---|---|---|
| N1 | Medium | ToolbarView.swift:21; Packages/ShareXCore/Sources/ShareXCore/Geometry.swift:184-193; Annotation.swift:65 | The strength slider goes down to 2, and decoded styles clamp at 0. At strength 2 on a 1× display, pixelate uses 2-px blocks and blur uses sigma 4 px. Small text stays readable or can be recovered with Depix-style or deconvolution attacks. Defaults (blur 12, pixelate 10) are fine. This is a user-selectable weak setting, not a fail-open, so it doesn't block. | Raise the effect floor, for example pixelate ≥ 8 px and blur sigma ≥ 8 px after scale, in EffectMath. Optionally add a solid "Redact" tool. |
| N2 | Info | Export.swift:111-115 | Save As writes with `.atomic`, which replaces the destination. That's intended, because NSSavePanel already confirmed the overwrite. Symlink-at-destination behaviour is the standard Foundation atomic rename (the symlink is replaced, not followed). | None needed. |
| N3 | Low | Export.swift:89-93 (with F6) | Captures that include redactions still go to the general pasteboard, so Universal Clipboard and clipboard managers keep them. The pasted image is redacted, though, because it's the same encoded bytes as the file (CaptureCoordinator.swift deliver). | Add `org.nspasteboard.TransientType`. |

### Redaction / blur integrity (brief item 3): passes
- **Pixels are destroyed, not overlaid:** `effectPatch` (Renderer.swift:196-224) builds the patch only from the frame cropped to the region, with `clampedToExtent` so nothing bleeds in from outside, and renders it to its own CGImage. `Export.flatten` (Export.swift:20-32) draws the frame and then the patches into one bitmap context and returns a single `makeImage()`. No layer, alpha mask or original survives the flatten.
- **Metadata:** `encode` writes only the DPI properties (Export.swift:64-75). The PNG and the clipboard get the same bytes.
- **Fails closed:** if CoreImage fails (Renderer.swift:216-219), the mark is recorded in `failedRedactions` and `coverRedaction` paints opaque black with `.copy` blend at alpha 1 (Renderer.swift:181-185). `coverRedactionFailures` repaints every failed mask as the last layer after all marks (Renderer.swift:64, 187-191), so later effects that sample the original frame can't uncover it. The editor UI shows the failures (EditorLayers.swift:53,145-147).
- **Empty or out-of-bounds region:** `pixelRect(...).clamped` returns nil only when the region doesn't intersect the frame (Renderer.swift:197-199). In that case there are no pixels to hide, and the export crop is clamped to the same frame (Export.swift:22). A partly out-of-bounds region is clamped and fully covered.
- UNVERIFIED: runtime pixel equivalence. E2ERedaction.swift exists as a CI test, but its results weren't seen here.

## UNVERIFIED (static only)
- That the DMG strings/nm gate and the `runtime` flag assertion actually pass in CI for HEAD.
- The embedded entitlements of the built app.
- KeyboardShortcuts revision `045cf17…` equals upstream tag 2.3.0.
- Whether `.sha256` gets attached to the GitHub Release (only uploaded as a workflow artifact).
- ScreenCaptureKit honouring `sharingType = .none`.
- Runtime redaction pixel results and the CoreImage failure path.

## Reviewed tree state
- Branch `fix/magnifier`, HEAD `382ef6a03dd59492676e172c89b012c27b222759` ("Loupe: hover via always-on tracking area…").
- `git status --short` at start was clean (no modified or untracked files).
- Only this file was added (reviews/final-security.md).
