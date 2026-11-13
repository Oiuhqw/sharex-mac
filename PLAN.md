# ShareX for macOS implementation and verification

Version 0.2.0, build 8 adds local agent screenshots, silent MP4 recording, CLI and MCP control, durable capture sessions, and native setup controls. The older proposals in `plans/` are historical.

## Implemented design

The app is a native menu-bar application for macOS 14 or later on Apple Silicon. Intel Macs are unsupported. AppKit owns capture windows and editing. SwiftUI owns Settings. ScreenCaptureKit supplies display and window images. CoreGraphics and CoreImage render the output. KeyboardShortcuts 3.1.0 supplies global shortcuts and is the only external runtime package.

`Packages/ShareXCore` contains geometry, capture options, annotations, the editor document, undo history, desktop layout, and stored settings. `Packages/ShareXAgent` contains the operation catalog, CLI, MCP, local transport, and protocol types. `App/Sources` contains platform adapters and the UI.

`AgentCaptureService` coordinates explicit capture targets and session operations. `ScreenRecorder` uses ScreenCaptureKit and AVAssetWriter. `CaptureSessions` persists atomic session state and artifacts. Agent access is off by default. A private per-user socket accepts same-user clients. The app shows recording status and stop controls. The [agent design](docs/AGENT-CAPTURE-DESIGN.md) describes limits, retry behavior, and recovery.

The capture path checks permission, applies the selected delay, freezes pixels, and opens selection or editing. `EditorSession` owns one document, gesture, history, native text field, renderer, and terminal outcome. A borderless panel on each original display projects that shared state into local coordinates. Window captures open a titled canvas around a fresh still image.

`DesktopImageSource` retains native display tiles and their point placements. It does not allocate the desktop union. Export allocates the selected crop at the highest scale among displays with a positive-area intersection. Empty desktop gaps remain transparent. An untouched Retina display does not increase a 1x crop's scale.

The toolbar stays at the safe top of each display. Direct tool icons, Style, Undo, Redo, Delete selected, Done, and Cancel remain available by mouse. All panels share annotations and undo. A drag across displays remains one gesture. A layout change during editing cancels the session once.

Last Region stores participant frames relative to an anchor display while retaining the original settings keys. It accepts common translation, backing-scale changes, and extra untouched displays. A missing, moved, or resized participant starts fresh Region selection. The coordinator revalidates after a countdown and against returned frozen geometry.

Export flattens the selected area, adds any border or shadow, and encodes PNG and TIFF. Clipboard and local PNG writes have separate results. Retry repeats only failed destinations. Last Region updates only after an output succeeds.

## User controls

- Eight capture modes cover Region, Freehand, Window, Active Window, Monitor, Active Monitor, Fullscreen, and Last Region.
- The magnifier and crosshair support area selection and crop changes. Size labels show image pixels before border or shadow padding.
- Direct tool icons provide boxes, ellipses, lines, arrows, highlighter, blur, pixelation, Smart Eraser, spotlight, pen, text, step markers, selection, and crop.
- Style shows color, numeric values, and a preview. Color, width or text size, opacity, fill, and effect strength update live. One slider drag creates one undo entry.
- Smart Eraser uses at most 512 unprotected ring samples and a fixed 32 by 32 RGBA patch. Unsuitable repairs stay opaque. Move, resize, undo, redo, and export use the same repair result.
- The toolbar states the output destination. A generated 90 ms shutter click plays after all requested outputs succeed.
- Capture, Shortcuts, and Output settings include shortcut search, recording, conflict feedback, clear, and restore controls.
- New installations assign only Control-Shift-1 for Region. Existing valid assignments remain unchanged. Editing keys are optional.
- New installations copy to the clipboard and save a local PNG. Existing output preferences remain unchanged.

## Privacy and resource rules

Earlier protected pixels remain protected when later blur or pixelation overlaps them. Later filter input replaces protected pixels with opaque black. Unsafe or over-budget effect operations use an opaque fallback. Blur and pixelation obscure detail but do not guarantee that the original content cannot be inferred.

Output images are limited to 64 Mi pixels. Effect source samples are limited to 16 Mi pixels. Committed effect patches are limited to 64 MiB and 128 entries. The cached live effect preview is limited to 16 MiB. Protection lookup is bounded by 1,024 candidates and 64 intersections per effect. These limits do not cap total process RSS.

Stored settings are limited to 1 MiB before parsing. Each owned shortcut string is limited to 1 KiB before decoding and must fit native integer widths. Recovery preserves valid assignments and leaves conflicting recovered defaults disabled.

Other recording apps can capture the editor before redaction is complete. The app does not claim that `NSWindow.sharingType` excludes modern recording APIs.

## Verification

The [current verification report](.audit/capture-polish-verification.md) contains the diagnostic source and exact native results. The [performance assessment](.audit/performance-finalization.md) explains the measured CPU and RAM costs without claiming an unmeasured speedup. The `macOS` workflow runs script tests, the core suite, AddressSanitizer, baseline app E2E, shortcut recovery, two virtual-display layouts, Release checks, and memory ownership checks.

The virtual helper creates two 1280 by 800 logical displays at 1x and 2x. Horizontal and vertical layouts include negative origins. Frozen tiles use deterministic fixture pixels on real `NSScreen` geometry. Actual ScreenCaptureKit window images cross-check editor projection and effects. Clipboard and PNG checks inspect delivered images. Layout mutation checks cover Last Region during the countdown and after freezing.

The helper must release its display objects and remove both created IDs from a successful online-display enumeration. The production app must exclude the helper, its private APIs, and all `SHAREX_E2E` code. An external process timeout records a native stack sample if the test driver stalls.

The strict metrics validator covers 28 timing series, six paired renderer cases, and two resource scenarios. It checks event delivery, completed output operations, and object release. The Release hover gate requires p95 main-thread CPU below 2 ms. Elapsed time and display-link callbacks remain diagnostics, not physical presentation measurements.

Memory checks record repeated sessions, buffer limits, object release, current RSS, peak RSS, and idle CPU. A separate process diagnoses image-provider lifetime and context caches. A successful ownership check does not establish a low memory footprint. Hosted-runner measurements do not support a relative speedup claim.

## Delivery status

Version 0.2.0, build 8 targets arm64 only. The [release](https://github.com/Oiuhqw/sharex-mac/releases/tag/v0.2.0) provides the DMG, checksum, and installation instructions. The release notes identify the verified PR, merged source, production package run, and DMG checksum. [Build and publish a release](docs/RELEASING.md) defines the release steps.

The diagnostic package, final PR package, and merged-main package have separate identities. `INSTALL.txt` is included in the DMG. Diagnostic validation therefore does not establish the final release checksum. The checksum in the release notes is the reference for download verification.

Packaging requires all mandatory native checks to pass. It verifies arm64 architecture, the app icon, Hardened Runtime signing, test-code exclusion, launch, and installation. Both hosted workflows return to disabled after the validation and release session.

## Historical evidence and remaining checks

The source security audit at `e8f9596` covered 47 source units and reported no qualifying vulnerability. The subsequent reliability fixes received a separate source review. Those conclusions remain tied to their revisions. They do not constitute a complete security audit of 0.1.3.

The 0.1.2 assessment and its Intel results are historical. Intel is outside current support and release gates. The full fuzz campaign remains incomplete. Deterministic property tests and AddressSanitizer results are reported at the scale that ran.

The package is ad-hoc signed with Hardened Runtime and is not notarized. Developer ID signing and notarization require the owner's Apple credentials.

Physical mouse transitions, separate Spaces, physical display hot-plug, real mixed-density display capture, physical shortcuts, and interactive permission prompts remain hardware checks. Scrolling capture, video, GIF recording, OCR, uploads, and re-editing a prior capture remain outside this version's scope.
