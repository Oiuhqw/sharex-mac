# ShareX for macOS (screenshots + annotation)

A native menu-bar port of ShareX's screenshot and annotation features. It has no uploads, video, GIF or OCR.
Swift 6, AppKit, ScreenCaptureKit, macOS 14+. Building requires Xcode 26.3 or later.

See the [user guide](docs/USER-GUIDE.md) for capture, editing, shortcuts, and output recovery. See the [review index](reviews/README.md) for validation evidence and limits.

## Configure signing for local development
```sh
cp Local.xcconfig.example Local.xcconfig   # then put your Apple team ID in DEVELOPMENT_TEAM
```
Local development builds use the Apple team configured above. The packaged DMG is signed ad-hoc.
An ad-hoc update can change its signing identity, and macOS may require a new Screen Recording grant.
`Local.xcconfig` is git-ignored.

Unsigned builds (`CODE_SIGNING_ALLOWED=NO`, as in CI) skip the Local.xcconfig marker check. Builds that enable code signing require that marker. This check does not validate the team ID.
## Features
- **Capture styles:** Region, Freehand (lasso), Window picker, Active window, Monitor picker, Active monitor, Fullscreen and Last region.
- **Before capture (menu › Before capture, or Settings):** delay 0/1/2/3/5/10 s with a countdown that never appears in the shot, show cursor, magnifier and crosshair, border, drop shadow, and "open editor for fixed-area captures".
- **Editor:** the screen freezes and you annotate in place. Tools and their keys:
  - Select/move/resize `V`
  - Rectangle `R`, Ellipse `E`, Line `L`, Arrow `A`
  - Highlighter `H`, Blur `B`, Pixelate `P`, Spotlight `S`
  - Pen `F`, Text `T`, Numbered step `I`
  - Crop `C`
- **Editor controls:** colour, width, opacity, strength and fill. Delete removes the selected mark, arrow keys nudge it (⇧ moves 10 pt), ⌘Z undoes and ⇧⌘Z redoes. Shift-drag constrains a shape. With Crop selected, arrow keys move the crop by one image pixel, ⇧ moves ten pixels, and ⌥ adjusts the right or bottom edge. The size label shows the crop dimensions in image pixels. Border and shadow can increase the final image size.
- **Finish:** Enter (or ⌘C, or Done) copies PNG + TIFF to the clipboard. Esc cancels. A right-click deletes the mark under the cursor; with no marks it resets the selection (or cancels a fixed-area capture). Blur and pixelate are burned into the pixels.
- **Local copy:** new installations also save the PNG to `~/Pictures/ShareX`. Existing save preferences are preserved. Clipboard and file writes are independent. If an output fails, Retry attempts only the failed destination and Save As lets you keep the PNG elsewhere. The success sound plays only after every requested output succeeds.
- **Default hotkeys** (rebindable in Settings › Shortcuts): ⌃⇧1 region, ⌃⇧2 window, ⌃⇧3 fullscreen, ⌃⇧4 active monitor, ⌃⇧5 freehand.
- **Settings:** Capture, Shortcuts, and Output pages. Search all eight capture commands, record a shortcut, clear it, or restore defaults. Conflicting assignments show an explanation. Damaged shortcut preferences recover at launch while preserving valid custom assignments. Choose the PNG destination with the native folder picker.

## Layout
```
Packages/ShareXCore/     platform-free logic + tests (builds on Linux): Geometry (CGRect points vs PixelRect pixels),
                         Capture options/styles, Annotation model, EditorDocument (undo), EffectMath/StitchLayout, Settings
App/Sources/             AppKit app: Main, CaptureCoordinator, ScreenCapture (SCK), OverlayController,
                         EditorView, ToolbarView, Renderer (CoreImage blur/pixelate), Export, Countdown, Permissions, Hotkeys, Settings*
project.yml              XcodeGen project (app target + local ShareXCore + pinned KeyboardShortcuts 3.1.0)
reviews/                 macOS Developer review request / feedback
```

## Build
Use Xcode 26.3 or later for the Swift 6.2 dependency toolchain. The app still runs on macOS 14 or later.

```sh
brew install xcodegen
xcodegen                    # generates ShareXMac.xcodeproj
open ShareXMac.xcodeproj    # Run (team comes from Local.xcconfig, step 1)
swift test --package-path Packages/ShareXCore   # core logic tests (also run on Linux)
```
Keep the signing team and bundle ID (`com.sharexmac.ShareX`) stable. Screen Recording permission is tied to the signature. To retest the permission flow, run `tccutil reset ScreenCapture com.sharexmac.ShareX`.

## Build and verification
- The macOS workflow compiles the app, runs the core tests normally and with AddressSanitizer, launches the native E2E driver, and records Release performance and resource measurements. Its artifacts contain results, UI screenshots, logs, process RSS, and CPU samples. A strict validator rejects missing measurements and failed output operations.
- After those checks pass, the same workflow builds a universal Release DMG, verifies its icon and signature, checks that test code is absent, and runs launch/install smoke checks.
- Version 0.1.1 adds independent output recovery, failure-injection regression cases, an app icon, and absolute save-folder validation.
- Version 0.1.2 adds shortcut configuration, pixel crop adjustments, preservation of earlier redactions, and image allocation limits. Effect patches retain at most 64 MiB across 128 cache entries, and the cached live effect preview retains at most 16 MiB. These are buffer limits, not a claim about total process memory. Capture and output images are limited to 64 Mi pixels; an oversized request reports an error.
- Hosted runners use fixture display frames when their desktop is blank; real window captures still use ScreenCaptureKit when permission is available. Physical hotkeys, real multi-display/Retina hardware and interactive permission prompts still need a Mac check. A green CI run does not certify those scenarios.
- CI defaults to `macos-15-intel`; manual runs can select the Apple Silicon `macos-15` pool. The package job uses the selected runner and still builds both architectures.
- The hover performance gate requires Release p95 main-thread CPU below 2 ms and verifies that the events updated the loupe. Debug elapsed time, Release wall time, and the next display-link callback are recorded separately. Hosted-runner display callbacks do not measure physical screen presentation.

## Known limitations
- Window picker and active window capture the window live with ScreenCaptureKit (`desktopIndependentWindow`), so covered windows come out whole, with transparent corners, no cursor, and the app-drawn shadow and border around the window itself (the system shadow is dropped until its sizing is verified on a Mac). The window is captured when you click it, not at the moment the overlay opened.
- Fullscreen on several displays stitches them into one image; with "open editor" on it is edited in a window (scaled to fit), otherwise copied directly.
- A region cannot span two displays: each display has its own overlay and the selection stays on one of them. Use Fullscreen for a multi-display shot.
- Blur and pixelate are visual obscuring tools. Use a fully opaque filled rectangle for content that must be completely hidden.
- Other screen-recording or screen-sharing apps may capture the editor, including the frozen image before you finish redacting it. `NSWindow.sharingType` does not provide a supported capture-exclusion guarantee on current macOS. See [Apple's window sharing documentation](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none).

## Founder's Mac checklist
**Setup**
- [ ] Xcode 26.3+ (Swift 6.2). Deployment target 14.0.
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
- [ ] Text: select Text (T), then click the existing text to edit it. Enter or a click elsewhere commits it.
- [ ] Numbered steps renumber after one is deleted.
- [ ] Blur and pixelate match the exported pixels. Fully opaque privacy boxes remain opaque when later effects overlap them.
- [ ] Highlighter tints the area without hiding the text, and spotlight dims everything outside the shape.
- [ ] Crop changes the output size.
- [ ] Clicking the toolbar does not stop the keys from working.

**Clipboard and hotkeys**
- [ ] The pasteboard holds both `public.png` and `public.tiff`, and the image keeps its Retina size (points = pixels / scale).
- [ ] Hotkeys work from any app, including full-screen ones. Rebinding persists after a relaunch.

**Release**
- [ ] Archive → Developer ID → `xcrun notarytool submit --wait` → `xcrun stapler staple` → `spctl -a -vv` passes on a clean account.

## Installing the DMG (unsigned by Apple)

The DMG is ad-hoc signed with the Hardened Runtime but **not notarized**. The CI packaging workflow does not
use Developer ID signing or Apple notarization. Gatekeeper can block the first open of a downloaded copy.
Either:

- open it once, then **System Settings → Privacy & Security → Open Anyway**, or
- remove the quarantine flag: `xattr -dr com.apple.quarantine /Applications/ShareX.app`

**If capture permission stops working after an update, re-grant Screen Recording.** An ad-hoc build can have
a different signing identity, so macOS may not retain the old grant. Open
**System Settings → Privacy & Security → Screen Recording**, remove
ShareX with **−**, add the new `/Applications/ShareX.app` with **+** (or toggle it on when prompted), then quit
and reopen ShareX. `tccutil reset ScreenCapture com.sharexmac.ShareX` clears the stale entry from Terminal.

Verify the download first: `shasum -a 256 ShareX.dmg` must match `ShareX.dmg.sha256` from the same CI run.
