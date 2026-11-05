# ShareX for macOS

ShareX is a native menu-bar app for screenshots and annotation. It supports macOS 14 or later on Apple Silicon. Intel Macs are unsupported. Uploads, video, GIF recording, and OCR are outside this version's scope.

Use the [user guide](docs/USER-GUIDE.md) for capture, editing, shortcuts, and output recovery. The [review index](reviews/README.md) records validation evidence and its limits.

## Latest built package

Version **0.1.3, build 4** supports **Apple Silicon Macs running macOS 14 or later**. The app contains arm64 code only. **Intel Macs are unsupported.** Download `ShareX.dmg`, `ShareX.dmg.sha256`, and `INSTALL.txt` from the [0.1.3 GitHub release](https://github.com/Oiuhqw/sharex-mac/releases/tag/v0.1.3).

Verify the DMG against the checksum attached to that same release. The release notes identify the merged source and package build. The app is ad-hoc signed with Hardened Runtime and is not Apple-notarized. Read the [installation instructions](INSTALL.txt) before opening it.

## Capture and edit

Open the camera icon in the menu bar and choose a capture command. ShareX has eight capture modes: Region, Freehand, Window, Active Window, Monitor, Active Monitor, Fullscreen, and Last Region.

Fullscreen editing stays on the original displays. Region and freehand selections can cross display boundaries. Each display has a fixed top toolbar with **Tool**, **Style**, **More**, **Done**, and **Cancel**. All panels share one document and undo history.

- **Tool** selects an annotation or crop tool. Before selection, it offers Region, Freehand, Window, Monitor, and Full Desktop.
- **Style** changes color, width or text size, opacity, fill, and blur or pixelation strength.
- **More** offers Undo, Redo, and Delete selected.
- **Done** exports the image. **Cancel** closes the capture without export.

The editor includes Select, Crop, Rectangle, Ellipse, Line, Arrow, Highlighter, Blur, Pixelate, Spotlight, Pen, Text, and Step marker. Optional editing keys are listed in the [user guide](docs/USER-GUIDE.md).

A new installation assigns only **Control-Shift-1** for Region. The other seven capture commands start unassigned. Updates preserve valid saved assignments, including old defaults and disabled shortcuts. Settings lets you search commands, record shortcuts, clear assignments, and restore defaults.

New installations copy PNG and TIFF to the clipboard and save a PNG in `~/Pictures/ShareX`. Updates preserve existing output preferences. Clipboard and file writes have separate results. If an output fails, **Retry** repeats only the failed destination. **Save As** saves the PNG elsewhere. The success sound plays only after every requested output succeeds.

Capture settings include a delay, cursor inclusion, a magnifier and crosshair, a border, a shadow, and an option to open the editor for fixed-area captures. Border and shadow can increase the final image size.

## Multi-display behavior

The editor retains frozen native display tiles. The output uses the highest scale among the displays that the crop touches. An unrelated Retina display does not increase a small 1x crop's scale. Empty desktop gaps remain transparent.

Output is limited to 64 Mi pixels. If a fullscreen output exceeds that limit, editing remains available. **Done** stays disabled until **Tool > Crop** reduces the area. The app does not reduce image detail to fit the limit.

Last Region supports areas across displays. Common desktop translation, scale changes, and extra untouched displays preserve the saved area. A moved, resized, or missing participating display starts a new Region selection. Old single-display settings still decode and clamp. The saved region changes only after an output succeeds.

Window and Active Window capture a fresh still image with ScreenCaptureKit. When editing is enabled, these captures open a titled canvas. Covered windows are captured whole. Transparent corners remain transparent, and the app adds the requested border or shadow. Window captures omit the pointer and the unverified system window shadow.

See [multi-display capture and validation](docs/MULTI-DISPLAY.md) for the shared session, native checks, and hardware limits.

## Privacy and resource limits

Blur and pixelation obscure detail. They do not guarantee that the content cannot be inferred. Use a fully opaque filled rectangle to cover sensitive content. Check the exported image before sharing it.

Later blur and pixelation operations preserve earlier protected pixels. Unsafe or over-budget effect operations use an opaque fallback. Committed effect patches retain at most 64 MiB across 128 entries. The cached live effect preview retains at most 16 MiB. These are buffer limits, not a cap on total process memory.

Other screen-recording or screen-sharing apps can capture the editor before redaction is complete. Stop those apps before opening sensitive content. `NSWindow.sharingType` does not guarantee capture exclusion.

## Build

Use an Apple Silicon Mac with Xcode 26.3 or later for the Swift 6.2 dependency toolchain. The project targets arm64 only and macOS 14 or later.

To configure local development signing:

```sh
cp Local.xcconfig.example Local.xcconfig
```

Set `DEVELOPMENT_TEAM` in `Local.xcconfig` to your Apple team ID. The file is ignored by Git. Then generate and open the project:

```sh
brew install xcodegen
xcodegen
open ShareXMac.xcodeproj
```

Run the core tests with:

```sh
swift test --package-path Packages/ShareXCore
```

Local signed builds use the configured team. Builds with `CODE_SIGNING_ALLOWED=NO` skip the local-config marker check. The marker check does not validate the team ID.

Keep the signing team and bundle ID, `com.sharexmac.ShareX`, stable. Screen Recording permission depends on the app signature. An ad-hoc update can require a new permission grant.

## Build and verification

The [0.1.3 assessment](reviews/multidisplay-0.1.3.md) records the diagnostic source, native results, screenshots, resource checks, and coverage limits. The final PR records the independent review and native run for its final documentation head. The release notes identify the separate package built from merged main. `INSTALL.txt` is part of the DMG, so an earlier diagnostic package does not establish the final package identity.

The `macOS` workflow runs script tests, core XCTest cases, AddressSanitizer, native app E2E, shortcut recovery, two virtual-display layouts, and Release resource checks. Artifacts contain result JSON, native window images, clipboard and file checks, logs, process RSS, and CPU samples.

The virtual-display driver uses real `NSScreen` geometry with one 1x display and one 2x display. Frozen tile images are deterministic fixtures. ScreenCaptureKit captures the actual editor windows for native comparison. This coverage does not certify physical mouse transitions, separate Spaces, physical hot-plug, real mixed-density display capture, interactive permission prompts, or physical shortcut use.

The strict metrics validator checks 28 timing series, six paired renderer cases, and two resource scenarios. The hover gate requires Release p95 main-thread CPU below 2 ms and checks event delivery. Wall time and display-link callbacks remain diagnostics. They do not measure physical screen presentation time. No relative speedup is claimed from a hosted-runner sample.

Packaging runs only after the required validation job succeeds. Debug, performance, and packaged executables must contain exactly arm64. Package checks verify the icon and signature, reject E2E code and private virtual-display APIs, and run launch and installation smoke checks.

The owner keeps the `macOS` and `DMG` workflows disabled between validation sessions. To start a hosted validation session:

```sh
gh workflow enable macos.yml --repo Oiuhqw/sharex-mac
gh workflow enable dmg.yml --repo Oiuhqw/sharex-mac
gh workflow run macos.yml --repo Oiuhqw/sharex-mac --ref main -f runner=macos-15
```

After the session completes, restore both workflows to disabled:

```sh
gh workflow disable macos.yml --repo Oiuhqw/sharex-mac
gh workflow disable dmg.yml --repo Oiuhqw/sharex-mac
```

The earlier 47-unit security audit covers `e8f9596`. It is not a new security audit of 0.1.3. The full fuzz campaign remains incomplete. See the [review index](reviews/README.md) for the historical scope.

## Check on physical Macs

The following checks require physical hardware or interactive macOS behavior:

- Grant and deny Screen Recording on a clean account. Check the Settings link, then quit and reopen the app.
- Drag rectangular and freehand selections across physical displays in both directions. Include mixed scale, negative origins, and separate Spaces.
- Edit fullscreen captures on each original display. Click Tool, Style, More, Done, and Cancel on every panel.
- Move, resize, or disconnect a participating display before and during capture. Check fresh Last Region selection and safe session cancellation.
- Paste captures into Preview and another app. Check dimensions, transparent gaps, freehand edges, and redaction coverage.
- Use the assigned global shortcut while another app is active. Check custom bindings after relaunch.
- Confirm that overlays cover fullscreen apps and that the countdown does not appear in the output.

Developer ID signing and notarization require the owner's Apple credentials. They are separate release work and are not part of this ad-hoc package.

## Install the DMG

Download the DMG and checksum from the [same 0.1.3 release](https://github.com/Oiuhqw/sharex-mac/releases/tag/v0.1.3). In the download folder, verify the file:

```sh
shasum -a 256 -c ShareX.dmg.sha256
```

Open the DMG and drag ShareX to Applications. Gatekeeper may block the first launch because the app is not notarized. After the first launch attempt, use **System Settings > Privacy & Security > Open Anyway**.

If macOS reports that the verified app is damaged or still refuses to open it, remove its download quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/ShareX.app
```

If capture permission stops working after an update, remove the old ShareX entry from Screen Recording permissions. Add the updated `/Applications/ShareX.app`, then quit and reopen it. To clear a stale permission entry from Terminal:

```sh
tccutil reset ScreenCapture com.sharexmac.ShareX
```

## Source layout

| Path | Contents |
| --- | --- |
| `Packages/ShareXCore/` | Geometry, capture options, annotations, the editor document, undo, desktop layout, settings, and tests. |
| `App/Sources/` | AppKit windows, ScreenCaptureKit adapters, the shared editor session, native display tiles, rendering, output, and settings UI. |
| `project.yml` | XcodeGen project and pinned KeyboardShortcuts 3.1.0 dependency. |
| `scripts/` | Build, packaging, validation, and the external test-only virtual-display helper. |
| `reviews/` | Revision-specific review and validation evidence. |

## Earlier versions

Version 0.1.2 added shortcut settings, pixel crop adjustments, preservation of earlier redactions, and allocation limits. Its universal package and validation counts are historical. Current releases support Apple Silicon only.

Version 0.1.1 added independent output recovery, export failure checks, an app icon, and absolute save-folder validation.
