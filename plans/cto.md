> Historical planning proposal. See [the current implementation plan](../PLAN.md) for the accepted scope and design.

# ShareX for macOS (capture side): CTO technical plan
**Author:** CTO · **Date:** 2026-11-03 · **Status:** Planning (no application code yet)

## 1. Executive recommendation
- **Stack:** Swift 6, AppKit for everything that touches windows, overlays, hotkeys, and the pasteboard. SwiftUI only for Settings and the menu-bar popover. Capture uses **ScreenCaptureKit** only, with no CGWindowList fallback.
- **Minimum macOS: 14.0 (Sonoma).** `SCScreenshotManager` (single-frame capture) first ships in 14.0. `CGWindowListCreateImage` is deprecated in 14 and marked unavailable in the macOS 15 SDK, so a lower floor would mean keeping two capture engines. Where 15.2+ is present, use `SCScreenshotManager.captureImage(in:)` (rect capture in display space; availability **UNVERIFIED**, check in Xcode). Otherwise use the 14.0 path: `captureImage(contentFilter:configuration:)` with `sourceRect`.
- **Ship path: Developer ID + Hardened Runtime + notarization, outside the Mac App Store, first.** Distribute a DMG and add Sparkle later. Mac App Store is a later option and does not block v1.

## 2. Architecture
| Module | Responsibility |
|---|---|
| **AppShell** | `NSApplication` accessory app (`LSUIElement`), `NSStatusItem` menu, Settings (SwiftUI), launch-at-login via `SMAppService.mainApp` |
| **Permissions** | Screen Recording TCC preflight/request, onboarding window, deep link to System Settings, state cache |
| **Hotkeys** | Global shortcut registration (Carbon `RegisterEventHotKey`), conflict detection, user rebinding |
| **OverlayUI** | One borderless overlay `NSWindow` per `NSScreen`: region drag, window hover-highlight, lasso path, magnifier/crosshair, Esc/cancel |
| **CaptureEngine** | `SCShareableContent` enumeration, `SCContentFilter` construction, `SCScreenshotManager` capture, crop/mask, cursor, border/shadow compositing → `CGImage` |
| **CapturePipeline** | Orchestration: style + options → delay → (freeze frame?) → overlay → capture → post-process → output |
| **Clipboard / Output** | NSPasteboard write (PNG + TIFF), optional save-to-file, optional editor hand-off |
| **Editor (M3+, nice-to-have)** | Annotation canvas (arrows, rect, text, blur, crop) |

Data flow: `Hotkey/Menu → CapturePipeline(style, options) → Permissions.ensure → [delay] → OverlayUI(selection) → CaptureEngine(selection) → PostProcess → Clipboard`.

## 3. Stack call: ScreenCaptureKit vs legacy
- **ScreenCaptureKit** (12.3+; screenshots via `SCScreenshotManager` from 14.0). Supports per-display, per-window, and app-filtered capture. `SCStreamConfiguration` controls `showsCursor`, `sourceRect`, `width`/`height` (pixel size), `scalesToFit`, and `capturesShadowsOnly`/`ignoreShadowsSingleWindow` (14.0+, exact names **UNVERIFIED**). `SCContentFilter(display:excludingWindows:)` keeps our own overlay out of the frame.
- **CGWindowListCreateImage:** deprecated in 14, unavailable when building against the macOS 15 SDK. **Rejected.**
- **CGDisplayStream:** deprecated. **Rejected.**
- **`CGWindowListCopyWindowInfo`** is still usable for cheap window metadata such as bounds and z-order while hovering. Window identity for capture comes from `SCShareableContent.windows`.
- **`SCContentSharingPicker`** (14.0) is the system picker. Do not use it for v1, because ShareX's UX requires our own overlay. It matters only if the MAS path wants to avoid the persistent TCC prompt.
- **Freeze-frame strategy:** when the overlay opens, grab a full-display `CGImage` per screen and draw it under the selection UI, as ShareX does. The final crop comes from that frozen image. This removes a second capture, stops menus or tooltips from vanishing mid-selection, and makes lasso masking trivial.

## 4. Screen Recording permission (TCC)
- **APIs that require it:** all ScreenCaptureKit content capture (`SCShareableContent` returns an error or no content without it) and the window titles from `CGWindowListCopyWindowInfo`. Hotkeys (Carbon) do **not** need Accessibility. NSEvent *global* key monitors do need it, which is one reason we avoid them.
- **Detect:** `CGPreflightScreenCaptureAccess()` (10.15+, no prompt).
- **Request:** `CGRequestScreenCaptureAccess()` shows the system prompt once per install/bundle ID. Later calls do not re-prompt.
- **Deep link:** open `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`. The URL still works on macOS 13–15 System Settings (**UNVERIFIED on macOS 26**; test it).
- **Relaunch:** the grant usually takes effect only after the app restarts. Onboarding shows "Quit & Reopen" after the grant.
- **macOS 15+ recurring re-confirmation:** Sequoia periodically re-asks the user to allow apps that capture the screen (cadence changed during betas to roughly monthly; **UNVERIFIED** for current OS). UX: treat a denied state at capture time as recoverable.
- **Denied UX:** hotkey or menu → non-modal panel ("Screen Recording is off — Open Settings"). Never fail silently. The menu-bar icon shows a warning badge. No degraded capture mode exists, because without TCC we capture only the wallpaper and our own windows, so we refuse instead of producing a bad image.
- **Dev gotcha:** TCC keys on signing identity. Ad-hoc or changing signatures between builds cause repeated prompts. Fix: sign every debug build with a stable Apple Development team, or `tccutil reset ScreenCapture <bundle-id>`.

## 5. Global hotkeys
| Option | Verdict |
|---|---|
| Carbon `RegisterEventHotKey` (directly or via the `sindresorhus/KeyboardShortcuts` / `soffes/HotKey` SPM packages) | **Chosen.** No Accessibility permission, consumes the keystroke, works sandboxed and in MAS, still supported despite the "Carbon" label |
| `NSEvent.addGlobalMonitorForEvents` | Rejected: needs Accessibility/Input Monitoring, cannot swallow the event |
| `CGEventTap` | Rejected: Input Monitoring permission, overkill |
| `NSEvent.addLocalMonitorForEvents` | Used only inside the overlay (Esc, arrows, Space, Shift/Option modifiers) |

Recommendation: the **KeyboardShortcuts** package (recorder UI plus persistence, Carbon underneath). Defaults mirror ShareX/macOS conventions but avoid ⌘⇧3/4/5, which are system-owned (user-rebindable). Example: ⌃⇧1 region, ⌃⇧2 window, ⌃⇧3 fullscreen, ⌃⇧4 active monitor, ⌃⇧5 lasso. Show a warning when registration fails because of a conflict.

## 6. Overlay windows (region / window / lasso, multi-display)
- **One `NSPanel`/`NSWindow` per `NSScreen`**: `.borderless`, `isOpaque = false`, `backgroundColor = .clear`, `level = .screenSaver` (or `CGShieldingWindowLevel()` if menus still cover it), `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `hidesOnDeactivate = false`. The app activates on overlay open. Accessory policy means no Dock flash.
- **Cross-display drag:** each overlay forwards mouse events to a shared `SelectionController` in **global Cocoa coordinates** (origin bottom-left of the primary screen). The rect is clipped per screen when rendered. A region spanning displays is captured per display and stitched into one image. Phase M1 may restrict selection to one display and stitch in M3.
- **Coordinate conversion (the classic bug):** Cocoa uses bottom-left global coordinates, while CG/ScreenCaptureKit display coordinates are top-left with points per display. Convert to `CGDirectDisplayID` (`NSScreen.deviceDescription["NSScreenNumber"]`) and multiply by `backingScaleFactor` for pixels. Set `SCStreamConfiguration.width/height` to points × scale for native-Retina output. Mixed-DPI setups (Retina laptop + 1x external) are a required test case.
- **Excluding the overlay:** with the freeze-frame approach, the frame is captured *before* the overlay is shown, so nothing needs excluding. For any live capture, build `SCContentFilter(display:excludingApplications:[ourApp])` and set `NSWindow.sharingType = .none` on overlays as a second safeguard.
- **Window mode:** at hover time, hit-test the cursor against `SCShareableContent.windows` (on-screen, layer 0, sorted by z-order from `CGWindowListCopyWindowInfo`) and draw a highlight. On click, capture with `SCContentFilter(desktopIndependentWindow:)`. This gives a true window image even when the window is occluded, with optional system shadow.
- **Lasso:** record an `NSBezierPath` on the freeze frame. Output is the bounding-box crop with outside-path alpha = 0 (PNG keeps transparency).
- **Magnifier/crosshair:** a CALayer-backed loupe sampled from the frozen image (nearest-neighbour, 8–10x), with full-height and full-width crosshair lines, a pixel coordinate readout, and a size label. Option toggles it.
- **Spaces/fullscreen apps:** `.fullScreenAuxiliary` plus `.canJoinAllSpaces` puts the overlay above full-screen apps. Test with a full-screen Safari or Keynote space.

## 7. Clipboard
- Write **both PNG and TIFF**. `NSPasteboard.general.clearContents()` first, then one `NSPasteboardItem` with `setData(png, forType: .png)` and `setData(tiff, forType: .tiff)`. Alternatively use `writeObjects([NSImage])`, which only gives TIFF; we prefer explicit data.
- Why both: modern apps (Slack, browsers, Figma) read `public.png`, while older Cocoa and Office paths read `public.tiff`. PNG keeps lasso alpha.
- Encode PNG with `NSBitmapImageRep(cgImage:).representation(using: .png, properties: [:])` or `CGImageDestination` with `UTType.png`. Keep **pixel-exact Retina** output and set the DPI metadata to 144 for 2x so pasted images display at point size. This is a setting (ShareX users expect full pixels).
- Reliability: write on the main thread, synchronously after capture, and check `changeCount` increments. Large captures (5K multi-display) are tens of MB as TIFF. Acceptable; optionally provide the TIFF lazily via `NSPasteboardItemDataProvider` (M3).
- Optional "also save to file" (`~/Pictures/ShareX/` by default, pattern `yyyy-MM-dd_HH-mm-ss.png`).

## 8. Sandbox, Hardened Runtime, notarization
- **No entitlement exists for screen recording.** It is purely a TCC user grant. `com.apple.security.device.camera` is the camera and is irrelevant. Don't add it.
- **Developer ID (v1):** Hardened Runtime ON (required for notarization). No special entitlements needed: no JIT, no `disable-library-validation` (all SPM dependencies are statically linked and signed with our team), no Apple Events. Notarize with `xcrun notarytool submit --wait` and then run `xcrun stapler staple`.
- **App Sandbox:** ScreenCaptureKit works sandboxed, with the same TCC prompt. Carbon hotkeys work sandboxed. Save-to-file needs `com.apple.security.files.user-selected.read-write` (+ `files.pictures.read-write` for a default folder), with a security-scoped bookmark for a custom folder. No temporary exception should be required (**UNVERIFIED** until an MAS build passes review). Plan: **ship v1 unsandboxed Developer ID**, but keep the code sandbox-clean (no private APIs, no Accessibility) so a Mac App Store target is just a second scheme with an entitlements file.
- MAS risk: App Review may push `SCContentSharingPicker` for screen-sharing apps. A screenshot tool with its own overlay has precedent (CleanShot X ships outside MAS; others are in MAS). Treat this as an open question, not a v1 blocker.

## 9. Capture style matrix
| Style | Phase | API approach |
|---|---|---|
| Fullscreen (all displays) | M0 | Per-display `SCScreenshotManager` → stitch by global frame |
| Active monitor | M0 | Display under the cursor (`NSEvent.mouseLocation` → `NSScreen`) → one capture |
| Region | M1 | Freeze frame + overlay rect → crop |
| Window | M2 | Hover hit-test → `SCContentFilter(desktopIndependentWindow:)` |
| Freehand / lasso | M2 | Freeze frame + path mask → alpha PNG |
| Scrolling | **Deferred (M4, spike)** | Synthesized scroll (`CGEvent` scroll wheel, **needs Accessibility**) + repeated region capture + overlap stitching (Vision `VNTranslationalImageRegistrationRequest` or row-hash matching). Fragile across apps; ship only after a spike proves Safari/Finder/Xcode work |

## 10. Pre-capture options → pipeline
| Option | Where it applies |
|---|---|
| Delay timer (0/1/3/5/10 s) | Before freeze frame; on-screen countdown HUD excluded via `sharingType = .none` and hidden before capture |
| Cursor on/off | `SCStreamConfiguration.showsCursor`. For freeze-frame modes the cursor is captured at freeze time (cursor position = where the hotkey fired), which matches ShareX |
| Magnifier / crosshair | OverlayUI only, never in output |
| Border | Post-process: stroke N px colour around the final `CGImage` |
| Shadow | Window mode: keep the system shadow (filter/config option). Other modes: a synthetic drop shadow drawn in post-process with a padded transparent canvas |

The options are stored as one `CaptureOptions` value per style (per-hotkey overrides like ShareX's task settings in M3).

## 11. Risks / open questions for founder
1. **macOS 14 floor**: OK to drop Ventura (~small share)? Recommended yes.
2. **Recurring Sequoia TCC re-prompt**: unavoidable for non-picker capture. Accept it?
3. **Scrolling capture** needs Accessibility and is fragile. Confirm it stays a deferred spike.
4. **Retina output size**: pixel-exact (default) vs point-size. Pick a default.
5. **Distribution**: Developer ID DMG + Sparkle now, MAS later. Confirm. Requires a paid Apple Developer account ($99/yr).
6. **Editor scope** for v1: ship without one, or with a minimal crop/arrow/text/blur editor?
7. **Name/trademark**: "ShareX" is the upstream project's mark. Confirm naming before public release.

## 12. Phased build plan
- **M0 — Skeleton + permissions + fullscreen → clipboard (≈1 wk):** Xcode project (macOS app target, SPM deps: KeyboardShortcuts), menu-bar accessory app, permission onboarding/deep link, fullscreen and active-monitor capture, PNG+TIFF clipboard, Developer ID signing + notarization pipeline proven once.
- **M1 — Region overlay (≈1–1.5 wk):** per-screen overlay windows, freeze frame, drag/resize/arrow-key nudge, magnifier/crosshair, Esc cancel, multi-display + mixed DPI correct, global hotkeys + recorder.
- **M2 — Window + lasso (≈1 wk):** hover highlight, occluded-window capture, shadow toggle, lasso alpha mask, delay timer, cursor toggle, border.
- **M3 — Polish (≈1–2 wk):** settings UI, save-to-file, per-style options, cross-display region stitching, launch at login, Sparkle, optional minimal editor.
- **M4 — Scrolling spike** (time-boxed 1 wk; go/no-go).

## 13. Build-and-test checklist (founder's Mac)
**Setup**
- [ ] macOS 15 or 26 host, **Xcode 16.x or newer** (Swift 6, macOS 15 SDK at minimum). Deployment target 14.0.
- [ ] Apple Developer Program team set in Signing & Capabilities. Use "Apple Development" for debug, "Developer ID Application" for release. Hardened Runtime ON, App Sandbox OFF (v1).
- [ ] Bundle ID fixed (e.g. `com.<org>.sharexmac`). Never change it between test builds (TCC keys on it).
- [ ] Info.plist: `LSUIElement = YES`. Screen Recording needs no usage-description key.

**TCC grant**
- [ ] First launch → onboarding → system prompt → enable in System Settings › Privacy & Security › Screen & System Audio Recording → Quit & Reopen.
- [ ] Reset to retest: `tccutil reset ScreenCapture <bundle-id>`.
- [ ] Deny path: toggle off → hotkey shows the "Open Settings" panel, and the deep link lands on the right pane.

**Manual tests (each must paste correctly into Preview › New from Clipboard, Slack/Messages, and a browser field)**
- [ ] Fullscreen: single display, two displays, and the mixed Retina + 1x external setup. Image dimensions = native pixels.
- [ ] Active monitor follows the cursor's display.
- [ ] Region: tiny (1×1), full screen, drag from any corner, Esc cancels with nothing on the clipboard, crosses display boundary.
- [ ] Overlay appears above a full-screen app space, the menu bar, and the Dock, and never appears in the output.
- [ ] Window: occluded window is captured whole; shadow on/off; window on the second display.
- [ ] Lasso: transparent outside the path when pasted into Keynote/Figma (PNG path).
- [ ] Delay 3 s: countdown is not in the output; menus opened during the delay are captured.
- [ ] Cursor on/off honoured.
- [ ] Border/shadow applied as configured.
- [ ] Hotkeys work from any frontmost app, including full-screen; rebinding persists; conflict warning shows.
- [ ] Clipboard has both `public.png` and `public.tiff` (check with a small `NSPasteboard` dump or Clipboard Viewer from Additional Tools).
- [ ] Release: Archive → Developer ID export → `xcrun notarytool submit --wait` → `xcrun stapler staple` → `spctl -a -vv` reports "Notarized Developer ID" → installs and runs on a second clean Mac/user account.

## 14. CTO recommendation
**Build a Swift/AppKit, ScreenCaptureKit-only, macOS 14+ menu-bar app with Carbon hotkeys and freeze-frame per-screen overlays, and ship it notarized via Developer ID first — fullscreen-to-clipboard in M0, region in M1.**
