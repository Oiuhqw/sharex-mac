# ShareX for macOS (screenshots + annotation)

A native menu-bar port of ShareX's screenshot and annotation features. It has no uploads, video, GIF or OCR.
Swift 6, AppKit, ScreenCaptureKit only, macOS 14+.

## ⚠️ Step 1 before anything else: set your signing team
```sh
cp Local.xcconfig.example Local.xcconfig   # then put your Apple team ID in DEVELOPMENT_TEAM
```
Without a team the app is ad-hoc signed, the signature changes on every build, and macOS silently drops the
Screen Recording grant each time (captures then fail with the permission alert). `Local.xcconfig` is git-ignored.

Unsigned builds (`CODE_SIGNING_ALLOWED=NO`, as in CI) skip the Local.xcconfig check; signed builds without it stop with a clear error.
## Features
- **Capture styles:** Region, Freehand (lasso), Window picker, Active window, Monitor picker, Active monitor, Fullscreen and Last region.
- **Before capture (menu › Before capture, or Settings):** delay 0/1/2/3/5/10 s with a countdown that never appears in the shot, show cursor, magnifier and crosshair, border, drop shadow, and "open editor for fixed-area captures".
- **Editor:** the screen freezes and you annotate in place. Tools and their keys:
  - Select/move/resize `V`
  - Rectangle `R`, Ellipse `E`, Line `L`, Arrow `A`
  - Highlighter `H`, Blur `B`, Pixelate `P`, Spotlight `S`
  - Pen `F`, Text `T`, Numbered step `I`
  - Crop `C`
- **Editor controls:** colour, width, opacity, strength and fill. Delete removes the selected mark, arrow keys nudge it (⇧ moves 10 pt), ⌘Z undoes and ⇧⌘Z redoes. Shift-drag constrains a shape.
- **Finish:** Enter (or ⌘C, or Done) copies PNG + TIFF to the clipboard. Esc cancels. A right-click deletes the mark under the cursor; with no marks it resets the selection (or cancels a fixed-area capture). Blur and pixelate are burned into the pixels.
- **Optional:** also save the PNG to `~/Pictures/ShareX`.
- **Default hotkeys** (rebindable in Settings › Hotkeys): ⌃⇧1 region, ⌃⇧2 window, ⌃⇧3 fullscreen, ⌃⇧4 active monitor, ⌃⇧5 freehand.

## Layout
```
Packages/ShareXCore/     platform-free logic + tests (builds on Linux): Geometry (CGRect points vs PixelRect pixels),
                         Capture options/styles, Annotation model, EditorDocument (undo), EffectMath/StitchLayout, Settings
App/Sources/             AppKit app: Main, CaptureCoordinator, ScreenCapture (SCK), OverlayController,
                         EditorView, ToolbarView, Renderer (CoreImage blur/pixelate), Export, Countdown, Permissions, Hotkeys, Settings*
project.yml              XcodeGen project (app target + local ShareXCore + KeyboardShortcuts 2.x)
reviews/                 macOS Developer review request / feedback
```

## Build
```sh
brew install xcodegen
xcodegen                    # generates ShareXMac.xcodeproj
open ShareXMac.xcodeproj    # Run (team comes from Local.xcconfig, step 1)
swift test --package-path Packages/ShareXCore   # core logic tests (also run on Linux)
```
Keep the signing team and bundle ID (`com.sharexmac.ShareX`) stable. Screen Recording permission is tied to the signature. To retest the permission flow, run `tccutil reset ScreenCapture com.sharexmac.ShareX`.

## Status
- ShareXCore builds, and all of its tests pass on Linux (Swift 6.0.3).
- **The AppKit/ScreenCaptureKit layer has not been compiled yet.** It was written on Linux without the macOS SDK. Expect some first-build fixes: Swift 6 concurrency diagnostics and small API-signature mismatches.

## Known limitations
- Window picker and active window capture the window live with ScreenCaptureKit (`desktopIndependentWindow`), so covered windows come out whole, with transparent corners, no cursor, and the app-drawn shadow and border around the window itself (the system shadow is dropped until its sizing is verified on a Mac). The window is captured when you click it, not at the moment the overlay opened.
- Fullscreen on several displays stitches them into one image; with "open editor" on it is edited in a window (scaled to fit), otherwise copied directly.
- A region cannot span two displays: each display has its own overlay and the selection stays on one of them. Use Fullscreen for a multi-display shot.
- Blur and pixelate only use pixels from the original frame. A shape drawn underneath a blur gets covered, not blurred.

## Founder's Mac checklist
**Setup**
- [ ] Xcode 16+ (Swift 6). Deployment target 14.0.
- [ ] Team set; Hardened Runtime ON; App Sandbox OFF. Bundle ID never changes between test builds.
- [ ] `xcodegen && xcodebuild -scheme ShareX build` compiles clean (fix and report any errors).

**Permission**
- [ ] First capture → system prompt → enable in System Settings › Privacy & Security › Screen & System Audio Recording → Quit & Reopen.
- [ ] Deny path: toggle off → capture shows the "Open Settings" alert; the deep link opens the right pane.

**Capture (paste each into Preview › File › New from Clipboard, Slack/Messages and a browser field)**
- [ ] Fullscreen on one display, two displays, and a mixed Retina + 1x setup. The image size must match the native pixels.
- [ ] Active monitor follows the cursor. The monitor picker highlights screens and a click picks one.
- [ ] Region:
  - Try a tiny region, a full-screen region, and a drag from each corner.
  - Esc must leave the clipboard unchanged.
  - Clicking without dragging should snap to the window under the cursor.
- [ ] Window picker and active window work, including on the second display and with shadow on and off.
- [ ] Freehand: outside the path is transparent when pasted into Keynote or Figma.
- [ ] Last region replays the previous rectangle.
- [ ] Overlay covers full-screen apps, menu bar and Dock and never appears in the output.
- [ ] Delay 3 s: countdown not in output; a menu opened during the delay is captured.
- [ ] Cursor on/off, border and shadow are honoured.

**Editor**
- [ ] Every tool draws. Select, move and resize handles work, and Delete removes the selected mark.
- [ ] Undo and redo go through a full session.
- [ ] Text: double-click edits the text, and Enter or a click elsewhere commits it.
- [ ] Numbered steps renumber after one is deleted.
- [ ] Blur and pixelate stay unreadable after pasting, so the effect is burned into the pixels.
- [ ] Highlighter tints the area without hiding the text, and spotlight dims everything outside the shape.
- [ ] Crop changes the output size.
- [ ] Clicking the toolbar does not stop the keys from working.

**Clipboard and hotkeys**
- [ ] The pasteboard holds both `public.png` and `public.tiff`, and the image keeps its Retina size (points = pixels / scale).
- [ ] Hotkeys work from any app, including full-screen ones. Rebinding persists after a relaunch.

**Release**
- [ ] Archive → Developer ID → `xcrun notarytool submit --wait` → `xcrun stapler staple` → `spctl -a -vv` passes on a clean account.
