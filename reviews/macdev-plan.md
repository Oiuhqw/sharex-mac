# macOS Developer review: PLAN.md + plans/cto.md
Status: plan-level review. Nothing here has been compiled; [UNVERIFIED] = confirm in Xcode on a Mac.

## Must fix before code
1. **Overlay can't take keyboard input as written.** A `.borderless` NSWindow/NSPanel returns `false` from `canBecomeKey`, so Esc, Enter, tool hotkeys and text annotation never arrive. Subclass and override `canBecomeKey` (and `canBecomeMain` for the window under the cursor) to return `true`, then `makeKeyAndOrderFront`. Use `NSApp.activate()`: `activate(ignoringOtherApps:)` is deprecated in macOS 14.
2. **One coordinate model, enforced by types.** Cocoa global (bottom-left, points), CG/SCK display/window frames (top-left, points), and image pixels. `SCWindow.frame` and `SCDisplay.frame` are top-left. Flip using the *primary* screen height (`NSScreen.screens[0].frame.maxY`), not `NSScreen.main` (main = key-window screen). Wrap them as distinct types (e.g. `CocoaPoint`, `CGGlobalPoint`, `PixelRect`) in CaptureCore with one converter.
3. **Mixed-DPI stitching is undefined.** Fullscreen "stitch by global frame" across a 2x and a 1x display needs a rule: render the canvas at the max backingScaleFactor and upscale the 1x frames (or output per-display). Decide it explicitly; otherwise crops spanning displays shift by a factor of 2.
4. **Window mode vs freeze frame.** PLAN annotates in the overlay on the frozen frame, but CTO §6 captures the window live via `SCContentFilter(desktopIndependentWindow:)` on click. Pick one per mode: recommend capturing the window image at click, then opening the annotation overlay on that image. Note the live window may have changed since the freeze.
5. **Drop `NSScreenCaptureUsageDescription`.** I'm not aware of it being a real Info.plist key; Screen Recording has no usage string [UNVERIFIED, but don't ship it without proof].

## Should fix
6. `CGPreflightScreenCaptureAccess()` can report stale state until relaunch; the authoritative check is whether `SCShareableContent` succeeds. Treat its error as "denied".
7. Swift 6: `SCShareableContent`, `SCWindow`, `SCDisplay` are not documented as Sendable [UNVERIFIED]. Keep enumeration + filter building + capture on one actor (@MainActor pipeline is simplest); pass only `CGImage` (or a Sendable wrapper) across actors.
8. Shadow: `SCStreamConfiguration.ignoreShadowsSingleWindow` / `ignoreShadowsDisplay` / `capturesShadowsOnly` are macOS 14.0 [names likely right, UNVERIFIED]. With shadow on, the window image grows by the shadow inset; the border/crop math must use the image size, not `SCWindow.frame`.
9. `SCScreenshotManager.captureImage(in:)` (15.2) is optional; the 14.0 `sourceRect` path alone is enough. Skip the dual path in M0.
10. Magnifier: set `layer.magnificationFilter = .nearest` on the loupe layer, sampling from the frozen CGImage in *pixel* coordinates.
11. Clipboard: one `NSPasteboardItem`, PNG + TIFF, good. Keep alpha in the TIFF (build it from the same CGImage, not via a flattened NSImage). Setting 144 DPI on PNG is fine but some apps ignore it; keep the pixel-exact default.
12. Overlay level: `.screenSaver` is above the menu bar and Dock; `CGShieldingWindowLevel()` is overkill and also hides system alerts. Also set `NSWindow.sharingType = .none` on the countdown HUD *and* exclude our app in live-capture filters.

## Fine as is
Carbon hotkeys via KeyboardShortcuts (no Accessibility), ScreenCaptureKit-only with a 14.0 floor, unsandboxed Developer ID + notarization, stable signing to stop repeated TCC prompts, deferring scrolling capture.
