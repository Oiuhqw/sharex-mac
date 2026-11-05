# ShareX for macOS (screenshots + annotation)

A native menu-bar port of ShareX's screenshot and annotation features. It has no uploads, video, GIF or OCR.
Swift 6, AppKit, ScreenCaptureKit, macOS 14+ on Apple Silicon. Intel Macs are unsupported. Building requires Xcode 26.3 or later on an Apple Silicon Mac.

See the [user guide](docs/USER-GUIDE.md) for capture, editing, shortcuts, and output recovery. See the [review index](reviews/README.md) for validation evidence and limits.

## Latest built package

The last published build artifact is **0.1.2, build 3**. This historical package predates the Apple Silicon-only support policy. Version 0.1.3, build 4 targets arm64 only and still requires native validation. Download the `ShareX-dmg` artifact from the [successful main build](https://github.com/Oiuhqw/sharex-mac/actions/runs/42038241966), then extract `ShareX.dmg` and `ShareX.dmg.sha256`. GitHub may require sign-in to download Actions artifacts.

The package was built from merge commit `65a3e36433b3d2262d35c19ae69a21eae7b11316` on 5 November 2026. The DMG is 1,942,657 bytes. Its SHA-256 is:

```text
5fb0f0730b9e60178b13abddaddcc7e667b2aca8ff5a5366dc80a3a1bcdedb58
```

The package is ad-hoc signed with Hardened Runtime and is not Apple-notarized. Version 0.1.2 has not been published as a GitHub release. The existing public release is 0.1.1. Read the [installation instructions](INSTALL.txt) before opening it.

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
- **Editor:** the desktop freezes and you annotate on the original displays. A fixed top toolbar on each display has **Tool**, **Style**, **More**, **Done**, and **Cancel**. Region and freehand drags can cross display boundaries. Every panel shares the same undo history.
- **Tools:** Select, Crop, Rectangle, Ellipse, Line, Arrow, Highlighter, Blur, Pixelate, Spotlight, Pen, Text, and Step marker. **Style** controls color, width or text size, opacity, strength, and fill. **More** offers Undo, Redo, and Delete. Optional editing keys are listed in the [user guide](docs/USER-GUIDE.md).
- **Finish:** **Done** copies PNG and TIFF to the clipboard. **Cancel** closes the capture. A right-click deletes the mark under the pointer. With no marks it resets the selection or cancels a fixed-area capture. Border and shadow can increase the final image size.
- **Local copy:** new installations also save the PNG to `~/Pictures/ShareX`. Existing save preferences are preserved. Clipboard and file writes are independent. If an output fails, Retry attempts only the failed destination and Save As lets you keep the PNG elsewhere. The success sound plays only after every requested output succeeds.
- **Default shortcut:** Control-Shift-1 opens Region. The top **Tool** menu also offers Freehand, Window, Monitor, and Full Desktop before selection. All eight commands can have custom shortcuts in Settings.
- **Settings:** Capture, Shortcuts, and Output pages. Search all eight capture commands, record a shortcut, clear it, or restore defaults. Conflicting assignments show an explanation. Damaged shortcut preferences recover at launch while preserving valid custom assignments. Choose the PNG destination with the native folder picker.

## Layout
```
Packages/ShareXCore/     platform-free logic + tests (builds on Linux): Geometry (CGRect points vs PixelRect pixels),
                         Capture options/styles, Annotation model, EditorDocument (undo), EffectMath, DesktopLayout, Settings
App/Sources/             AppKit app: Main, CaptureCoordinator, ScreenCapture (SCK), OverlayController,
                         EditorSession, EditorView, ToolbarView, DesktopImageSource, Renderer (CoreImage blur/pixelate), Export, Countdown, Permissions, Hotkeys, Settings*
project.yml              XcodeGen project (app target + local ShareXCore + pinned KeyboardShortcuts 3.1.0)
reviews/                 macOS Developer review request / feedback
```

## Build
Use an Apple Silicon Mac with Xcode 26.3 or later for the Swift 6.2 dependency toolchain. The project builds arm64 only. The app runs on macOS 14 or later. Intel builds and Intel Macs are unsupported.

```sh
brew install xcodegen
xcodegen                    # generates ShareXMac.xcodeproj
open ShareXMac.xcodeproj    # Run (team comes from Local.xcconfig, step 1)
swift test --package-path Packages/ShareXCore   # core logic tests (also run on Linux)
```
Keep the signing team and bundle ID (`com.sharexmac.ShareX`) stable. Screen Recording permission is tied to the signature. To retest the permission flow, run `tccutil reset ScreenCapture com.sharexmac.ShareX`.

## Build and verification

As of 5 November 2026, the `macOS` and `DMG` GitHub Actions workflows are disabled at the owner's request. Their definitions remain in the repository. Pushes do not start these workflows until they are enabled. The existing package and its passing validation run remain available.

To resume hosted builds, enable both workflows and dispatch the full validation pipeline:

```sh
gh workflow enable macos.yml --repo Oiuhqw/sharex-mac
gh workflow enable dmg.yml --repo Oiuhqw/sharex-mac
gh workflow run macos.yml --repo Oiuhqw/sharex-mac --ref main -f runner=macos-15
```

- The main build at `65a3e36` passed 97 core tests, the same 97 under AddressSanitizer, 26 script tests, 420 normal E2E checks, and 63 shortcut-recovery checks. There were zero E2E failures and six explicitly unverifiable checks.
- The macOS workflow compiles the app, runs the core tests normally and with AddressSanitizer, launches the native E2E driver, and records Release performance and resource measurements. Its artifacts contain results, UI screenshots, logs, process RSS, and CPU samples. A strict validator rejects missing measurements and failed output operations.
- After those checks pass, the same workflow builds an arm64 Release DMG, verifies its architecture, icon, and signature, checks that test code and the private virtual-display helper are absent, and runs launch/install smoke checks.
- Version 0.1.1 adds independent output recovery, failure-injection regression cases, an app icon, and absolute save-folder validation.
- Version 0.1.2 adds shortcut configuration, pixel crop adjustments, preservation of earlier redactions, and image allocation limits. Effect patches retain at most 64 MiB across 128 cache entries, and the cached live effect preview retains at most 16 MiB. These are buffer limits, not a claim about total process memory. Capture and output images are limited to 64 Mi pixels; an oversized request reports an error.
- Hosted runners use fixture display frames when their desktop is blank; real window captures still use ScreenCaptureKit when permission is available. Physical hotkeys, real multi-display/Retina hardware and interactive permission prompts still need a Mac check. A green CI run does not certify those scenarios.
- CI and packaging run on Apple Silicon `macos-15`. Each job rejects a host whose architecture is not arm64. Debug, performance, and packaged executables must contain exactly the arm64 architecture.
- The hover performance gate requires Release p95 main-thread CPU below 2 ms and verifies that the events updated the loupe. Debug elapsed time, Release wall time, and the next display-link callback are recorded separately. Hosted-runner display callbacks do not measure physical screen presentation.

## Capture behavior and privacy

- Window picker takes a fresh still image when you click the window. Active Window also takes a fresh still image. Both use ScreenCaptureKit and open a titled canvas when editing is enabled. Covered windows are captured whole, with transparent corners and app-drawn border and shadow. The pointer is omitted from window captures.
- Fullscreen editing stays on the original displays. Direct fullscreen capture exports one image. Region and freehand selections can span displays. Empty desktop gaps stay transparent.
- Blur and pixelate obscure detail. Use a fully opaque filled rectangle when content must be completely hidden. Check the final image before sharing it.
- The system window shadow is omitted until its sizing is verified on a Mac.
- Other screen-recording or screen-sharing apps may capture the editor before redaction is complete. `NSWindow.sharingType` does not guarantee capture exclusion. See [Apple's window sharing documentation](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none).

## Founder's Mac checklist
**Setup**
- [ ] Apple Silicon Mac with Xcode 26.3+ (Swift 6.2). Deployment target 14.0. Intel Macs are unsupported.
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

## Multi-display editing in 0.1.3

Version 0.1.3, build 4 keeps fullscreen editing on the original displays. Region and freehand gestures can cross display boundaries. Every display has a fixed top toolbar with Tool, Style, More, Done, and Cancel. All panels share one document, text editor, undo history, and effect cache. Window capture still opens a titled editor around a fresh still image.

The output uses the highest scale among the displays touched by the crop. An unrelated Retina display does not increase the scale of a small 1x crop. Desktop gaps stay transparent. The editor retains native display tiles and allocates only bounded effect samples and the final crop. If a fullscreen output exceeds 64 Mi pixels, editing remains available. Done stays disabled until Crop reduces the area. There is no silent downsampling.

Last Region supports areas across displays. It accepts common desktop translation, backing-scale changes, and extra untouched displays. A moved, resized, or missing participating display starts a fresh Region selection. Old single-display settings still decode and clamp. The saved region changes only after an output succeeds.

A fresh installation assigns only Control-Shift-1. Updates preserve valid stored assignments, including old defaults and explicit disabled values. Restore All resets eight commands and assigns one shortcut. KeyboardShortcuts 3.1.0 stores initial bindings as explicit preferences, so an upgrade cannot distinguish an old default from a custom binding.

This source change requires native macOS validation before a new package is published. The existing artifact and signing status above still apply. See [multi-display validation](docs/MULTI-DISPLAY.md) for the driver and remaining hardware checks.
