> Historical review of an earlier revision. See [the review index](README.md) for current evidence and validation status.

# Final release review: fix/magnifier @ 382ef6a (PR #2 on PR #1)

**Verdict: SIGN, conditional on one on-device keyboard check (K1 below). If K1 fails, it becomes BLOCK until the NSPanel fix lands.**

There are no code blockers in what CI can prove. K1 is the only real risk, and it is pre-existing.

## Release items

| Area | Status | Evidence |
|---|---|---|
| Capture modes | ✅ | auto-* and editor-* PNGs for fullscreen, active monitor, active window, last region, monitor picker and window picker pass. E2E 194/200; the 6 failures are runner limits (see the magnifier signoff). |
| Overlay hover and loupe | ✅ | Tracking area plus `syncMouse`. HID hover works with the app inactive. Corners pass; reopen 20/20. |
| **Keyboard focus** | ⚠ **K1** | OverlayController.swift:145 `NSApp.activate()` can be declined (CI shows `appActive=false, isKey=false`), and then Esc, Enter, the hotkeys and text input go to the other app. No E2E test routes keys through the window server (E2E.swift:164–167, 656; E2EEditing.swift:59). Fix: non-activating `NSPanel` overlay plus a HID key E2E test (details in macdev-magnifier-signoff.md). |
| Annotations, redaction, undo | ✅ | editing-*, tool-*, release-endpoint-*, cross-reverse and redaction move/recovery 1× tests pass. The 2×-display-aligned failures are diagnostics on a 1× runner. |
| Clipboard and copy | ✅ | copy-cmdC, menu and double-click pass: PNG+TIFF, `savedEqualsClipboard`, sentinel gone. |
| Export recovery and focus | ✅ | `Focus.restore` falls back to `NSApp.hide(nil)` (CaptureCoordinator.swift:206–209). alert-windowGone-focus-restored and alert-no-previous-app-hides pass. |
| Orientation probe | ✅ | onscreen-orientation PASS: windowServer top dimmed, hole edges aligned. |
| Perf | ✅ hover and drag / ⚠ re-run | Hover p95 1.13 ms and region drag p95 1.22 ms are better than before. Commit, save and blur figures rose (commitToClipboard p95 341 vs 148 ms, savePNG p50 159 vs 85 ms) with no code change on those paths, so I attribute it to the runner. Re-run perf once; if it reproduces, it's a BLOCK. |
| DMG | ✅ | `/workspace/dmg-loupe/ShareX.dmg` sha256 a56cd429… matches the CI artifact and its .sha256 file. Unpacked (UDZO): `CFBundleIdentifier com.sharexmac.ShareX`, version 0.1.1, `LSMinimumSystemVersion 14.0`, **`LSUIElement true`**. **No E2E/SHAREX_E2E/E2ELoupe strings.** The codesign log shows `Signature=adhoc`, `flags=0x10002(adhoc,runtime)` (Hardened Runtime present) and no TeamIdentifier. spctl rejects it, as expected for a build that isn't notarized. INSTALL.txt explains the workaround. |
| KeyboardShortcuts pin | ✅ | project.yml:12 `exactVersion: 2.3.0`. Package.resolved is 2.3.0 @ 045cf17. |
| Quarantine probe fix | ✅ | dmg.yml:89–114: a perl alarm replaces `timeout` (no exit 127), and there's no `continue-on-error`. The log shows `open exit 142; launched with quarantine`, then a launch after `xattr -dr` (open exit 0). |
| Earlier blocker fixes (rounds 5/6) | ✅ | Still present at HEAD, and E2E covers them; nothing regressed. |

## Required before tagging
1. **K1 device check** on macOS 27: with another app frontmost, use the hotkey to open Region, press Esc to cancel, then draw a Text annotation and type into it. If it fails, ship the `NSPanel(.nonactivatingPanel)` overlay (OverlayController.swift:5–8 and :60-ish window creation) together with a HID key E2E test.
2. Re-run the perf job once to rule out the commit and save rise.
3. On-device multi-display: the loupe shows only on the screen under the cursor, and is hidden on exit.

Nits: make `ChromeView.contentsRectFlipY` a `let`, and add a "superseded" header to macdev-magnifier.md.
