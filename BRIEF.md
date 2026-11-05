# ShareX for macOS product brief

ShareX is a native screenshot and annotation app for macOS. Version 0.1.3, build 4 supports macOS 14 or later on Apple Silicon. Intel Macs are unsupported.

## Required workflow

- Select an area across one or more displays with a magnifier and pixel-accurate dimensions.
- Edit fullscreen captures on the original displays through one shared document and undo history.
- Use a fixed top toolbar for capture and annotation. Tool, Style, More, Done, and Cancel provide the normal mouse workflow.
- Add blur, pixelation, boxes, arrows, drawing, text, and other annotations. Support selection, movement, resizing, deletion, undo, and redo.
- Copy the finished image to the clipboard. Save a local PNG by default. Preserve existing output preferences.
- Keep capture, pointer movement, and editing responsive. Bound image allocations and retained effect buffers.
- Provide native settings for capture options, eight shortcut assignments, and the save folder. Assign only Control-Shift-1 for Region on new installations.
- Preserve valid saved shortcuts. Support search, recording, conflict feedback, clearing, and defaults.
- Check privacy, input boundaries, output recovery, dependencies, and release packaging. State the limits of the evidence.

Capture modes are Region, Freehand, Window, Active Window, Monitor, Active Monitor, Fullscreen, and Last Region. Window captures use a fresh still image. Display editing uses frozen native tiles. Neither workflow is a live video editor.

## Implementation scope

The app uses Swift, AppKit, ScreenCaptureKit, CoreGraphics, and CoreImage. Settings uses SwiftUI. KeyboardShortcuts 3.1.0 is the only external runtime package. App and package builds target arm64 only.

One shared editing session owns the document, history, gesture, text editor, renderer, and completion. Each original display projects that state into its own panel. The selected crop controls the output scale. Transparent desktop gaps remain transparent, and an unrelated display does not increase a crop's scale.

Uploads, video, GIF recording, OCR, scrolling capture, and reopening a previous editing document are outside this version's scope.

## Verification and delivery

The development host uses native Windows tools without WSL. Apple Silicon `macos-15` runners provide native builds, automated app checks, screenshots, clipboard and file checks, and Release measurements. Architecture assertions reject Intel and universal app binaries.

The [0.1.3 assessment](reviews/multidisplay-0.1.3.md) records the diagnostic source and native results. Automated display checks use deterministic frozen tiles on real 1x and 2x `NSScreen` geometry. ScreenCaptureKit captures actual editor windows to check visible content. These checks cover both horizontal and vertical layouts with negative origins.

Native E2E and independent source review must pass before merge. Confirmed findings require fixes and repeat checks. Documentation belongs in the final reviewed head. The PR records that head's independent native run. The [release](https://github.com/Oiuhqw/sharex-mac/releases/tag/v0.1.3) identifies the merged-main package and its checksum.

The package is ad-hoc signed with Hardened Runtime and is not notarized. Developer ID signing and notarization require the owner's Apple credentials.

Physical mouse transitions, separate Spaces, physical hot-plug, real mixed-density display capture, physical shortcuts, and interactive permission prompts remain hardware checks. Blur and pixelation do not guarantee that sensitive content is unrecoverable. An opaque filled rectangle provides complete coverage in the exported image.

The earlier 47-unit security audit covers its recorded revision, `e8f9596`. It does not certify the complete 0.1.3 patch. The full fuzz campaign remains incomplete. Current deterministic property tests and AddressSanitizer checks retain their actual scale and revision in the assessment.

See [README.md](README.md) for the package and [PLAN.md](PLAN.md) for the design and verification requirements.
