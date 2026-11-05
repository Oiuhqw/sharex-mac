# ShareX for macOS: product brief

Build a small, fast, native screenshot app for macOS. The product covers the screenshot and annotation workflow of ShareX.

## Required workflow

- Select an area with a magnifier and pixel-accurate dimensions.
- Add blur, pixelation, boxes, arrows, drawing, text, and other annotations. Support selection, movement, resizing, deletion, undo, and redo.
- Copy the finished image to the clipboard. Save a local PNG by default. Preserve an existing user's output preferences.
- Keep capture, pointer movement, and editing responsive. Bound image allocations and retained effect buffers.
- Provide native settings for capture options, eight global shortcuts, and the save folder. Support shortcut search, recording, conflict feedback, clearing, and defaults.
- Check privacy, input boundaries, output recovery, dependencies, and release packaging. State the limits of the security evidence.

Capture modes are region, freehand, window picker, active window, monitor picker, active monitor, fullscreen, and last region.

## Scope

The app uses Swift, AppKit, ScreenCaptureKit, CoreGraphics, and CoreImage. Settings uses SwiftUI. KeyboardShortcuts is the only external runtime package. The deployment minimum is macOS 14.

Uploads, video, GIF recording, OCR, scrolling capture, and reopening a previous editing document are outside this version's scope.

## Verification and delivery

The development host is Windows. Do not use WSL. GitHub macOS runners provide native builds, automated UI checks, screenshots, clipboard and file checks, and Release measurements. The package is universal for Apple Silicon and Intel.

Native E2E must pass before merge. The final security audit follows the implementation check; its confirmed findings must be fixed and checked again. Update the documentation before merging to main.

Hosted CI does not certify physical keyboard use, interactive permission prompts, or real mixed-display hardware. Blur and pixelation do not guarantee that sensitive content is unrecoverable. Use a fully opaque filled box for complete concealment.

See [README.md](README.md) for usage and [PLAN.md](PLAN.md) for the implemented design and remaining verification work.
