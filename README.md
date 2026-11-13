# ShareX for macOS

ShareX is a native menu-bar app for screenshots and annotation. It supports macOS 14 or later on Apple Silicon. Intel Macs are unsupported. The published 0.1.6 package does not include video recording. This development source adds agent screenshots and silent MP4 recording through a CLI and MCP. Uploads, GIF recording, and OCR remain outside scope.

Use the [user guide](docs/USER-GUIDE.md) for capture, editing, shortcuts, and output recovery. The [review index](reviews/README.md) records validation evidence and its limits.

Use the [agent capture guide](docs/AGENT-CAPTURE.md) for Claude Code and Codex setup, recording sessions, screenshots, evidence, and validation requirements. This feature has not been published in a release.

## Latest built package

Version **0.1.6, build 7** supports **Apple Silicon Macs running macOS 14 or later**. The app contains arm64 code only. **Intel Macs are unsupported.** Download `ShareX.dmg` from the [0.1.6 GitHub release](https://github.com/Oiuhqw/sharex-mac/releases/tag/v0.1.6).

Each release has one installer, `ShareX.dmg`. Installation instructions are included inside it. The release notes identify the merged source and package build. The app is ad-hoc signed with Hardened Runtime and is not Apple-notarized. Read the [installation instructions](INSTALL.txt) before opening it.

## Capture and edit

Open the camera icon in the menu bar and choose a capture command. ShareX has eight capture modes: Region, Freehand, Window, Active Window, Monitor, Active Monitor, Fullscreen, and Last Region.

For Region or Freehand, draw or redact before selecting the final area. Choose **Region** or press **Tab**, then drag the area and release to copy automatically. For a plain screenshot, drag immediately. No **Done** click is needed. Drawing and tool changes do not copy or save intermediate images.

Fullscreen editing stays on the original displays. Region and freehand selections can cross display boundaries. Each display has a fixed top toolbar with visible tool icons, **Style**, **Undo**, **Redo**, **Delete selected**, and **Cancel**. Hover over an icon to see its name and shortcut. The selected tool is highlighted and named below the buttons. Buttons wrap on narrow displays. Fixed-area editors also show **Done**. All panels share one document and undo history.

- Annotation buttons are available before selection, alongside Region, Freehand, Window, Monitor, and Full Desktop. Crop is available in fixed-area editors.
- **Style** shows the selected color, numeric values, and a preview. Sliders update the selected annotation as you drag, with one undo step per drag.
- **Undo**, **Redo**, and **Delete selected** are separate icon buttons.
- Releasing a Region or Freehand selection exports the image. **Done** exports from a fixed-area editor. **Cancel** or one press of **Esc** closes every capture window without export, including during text entry, a drag, or an open Style popover.

The editor includes Select, Crop, Rectangle, Ellipse, Line, Arrow, Highlighter, Blur, Pixelate, Smart Eraser, Spotlight, Pen, Text, and Step marker. Smart Eraser estimates nearby background pixels to remove small objects on plain or smooth backgrounds. It runs locally and supports move, resize, undo, and export. Optional editing keys and repair limits are listed in the [user guide](docs/USER-GUIDE.md).

A new installation assigns only **Control-Shift-1** for Region. The other seven capture commands start unassigned. Updates preserve valid saved assignments, including old defaults and disabled shortcuts. Settings lets you search commands, record shortcuts, clear assignments, and restore defaults.

New installations copy PNG and TIFF to the clipboard and save a PNG in `~/Pictures/ShareX`. Updates preserve existing output preferences. Clipboard and file writes have separate results. If an output fails, **Retry** repeats only the failed destination. **Save As** saves the PNG elsewhere. The success sound plays only after every requested output succeeds.

The toolbar shows whether the capture will copy and save, or copy only. The success sound is a short shutter click with a preview in Output settings. The circular magnifier retains the pixel marker and coordinate label for exact selection.

Capture settings include a delay, cursor inclusion, a magnifier, a border, a shadow, and an option to open the editor for fixed-area captures. Border and shadow can increase the final image size.

ShareX enables **Launch ShareX at login** on its first normal launch after this update. It uses the macOS login-item service. Settings shows whether registration is active or needs approval in System Settings. Turning it off in either Settings app remains effective after relaunch. Start ShareX once from Applications to register it. The capture pointer is a compact, symmetric crosshair with an open centre and a black outline.

## Multi-display behavior

The editor retains frozen native display tiles. The output uses the highest scale among the displays that the crop touches. An unrelated Retina display does not increase a small 1x crop's scale. Empty desktop gaps remain transparent.

Output is limited to 64 Mi pixels. If a fullscreen output exceeds that limit, editing remains available. **Done** stays disabled until **Crop** reduces the area. The app does not reduce image detail to fit the limit.

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

The [current verification report](.audit/capture-polish-verification.md) records the capture and editor checks. The [performance assessment](.audit/performance-finalization.md) records CPU and RAM measurements from three native runs. Each release's notes identify its source and validation run. `INSTALL.txt` is part of the DMG, so an earlier diagnostic package does not establish the final package identity.

The `macOS` workflow runs script tests, core XCTest cases, AddressSanitizer, native app E2E, shortcut recovery, two virtual-display layouts, and Release resource checks. Job logs retain check summaries, selected native images, and performance JSON. Actions artifact storage is opt-in.

The virtual-display driver uses real `NSScreen` geometry with one 1x display and one 2x display. Frozen tile images are deterministic fixtures. ScreenCaptureKit captures the actual editor windows for native comparison. This coverage does not certify physical mouse transitions, separate Spaces, physical hot-plug, real mixed-density display capture, interactive permission prompts, or physical shortcut use.

The strict metrics validator checks 28 timing series, six paired renderer cases, and two resource scenarios. The hover gate requires Release p95 main-thread CPU below 2 ms and checks event delivery. Wall time and display-link callbacks remain diagnostics. They do not measure physical screen presentation time. No relative speedup is claimed from a hosted-runner sample.

The main validation workflow packages only after its validation job succeeds. The separate release procedure requires a verified merge before the DMG workflow runs. Debug, performance, and packaged executables must contain exactly arm64. Package checks verify the icon and signature, reject E2E code and private virtual-display APIs, and run launch and installation smoke checks.

The owner keeps the `macOS` and `DMG` workflows disabled between validation sessions. See [Build and publish a release](docs/RELEASING.md) for free standard-runner validation, draft uploads, package checks, and publication.

The earlier 47-unit security audit covers `e8f9596`. It is not a security audit of the complete 0.1.6 patch. The full fuzz campaign remains incomplete. See the [review index](reviews/README.md) for the historical scope.

## Check on physical Macs

The following checks require physical hardware or interactive macOS behavior:

- Grant and deny Screen Recording on a clean account. Check the Settings link, then quit and reopen the app.
- Drag rectangular and freehand selections across physical displays in both directions. Include mixed scale, negative origins, and separate Spaces.
- Annotate before region selection on each display. Choose Region or press Tab, then release the final selection and check the clipboard.
- Edit fullscreen captures on each original display. Click tool icons, Style, Undo, Redo, Delete selected, Done, and Cancel on every panel.
- Move, resize, or disconnect a participating display before and during capture. Check fresh Last Region selection and safe session cancellation.
- Paste captures into Preview and another app. Check dimensions, transparent gaps, freehand edges, and redaction coverage.
- Use the assigned global shortcut while another app is active. Check custom bindings after relaunch.
- Confirm that overlays cover fullscreen apps and that the countdown does not appear in the output.

Developer ID signing and notarization require the owner's Apple credentials. They are separate release work and are not part of this ad-hoc package.

## Install the DMG

Download [ShareX.dmg from the 0.1.6 release](https://github.com/Oiuhqw/sharex-mac/releases/download/v0.1.6/ShareX.dmg).

Open the DMG and drag ShareX to Applications. Gatekeeper may block the first launch because the app is not notarized. After the first launch attempt, use **System Settings > Privacy & Security > Open Anyway**.

If macOS reports that the downloaded app is damaged or still refuses to open it, remove its download quarantine flag:

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
| `Packages/ShareXAgent/` | Agent protocol, local transport, CLI, MCP, setup helpers, and tests. |
| `App/Sources/` | AppKit windows, ScreenCaptureKit adapters, the shared editor session, native display tiles, rendering, output, and settings UI. |
| `project.yml` | XcodeGen project and pinned KeyboardShortcuts 3.1.0 dependency. |
| `scripts/` | Build, packaging, validation, and the external test-only virtual-display helper. |
| `reviews/` | Revision-specific review and validation evidence. |

## Earlier versions

Version 0.1.2 added shortcut settings, pixel crop adjustments, preservation of earlier redactions, and allocation limits. Its universal package and validation counts are historical. Current releases support Apple Silicon only.

Version 0.1.1 added independent output recovery, export failure checks, an app icon, and absolute save-folder validation.
