# ShareX for macOS: planning brief
Goal: a full working native macOS port of ShareX's capture side.
Must have:
- Capture styles chosen BEFORE taking the screenshot (as in ShareX): region, window, fullscreen, active monitor, freehand/lasso, scrolling capture if feasible, plus pre-capture options (delay timer, cursor on/off, magnifier/crosshair, border/shadow style).
- Result copied to the clipboard reliably (image data on NSPasteboard).
Nice to have: post-capture annotation editor, save to file, hotkeys, menu-bar app.
Out of scope: uploading to servers, URL shorteners, destinations.
Constraints: our build machine is Linux, so we cannot compile or run macOS code. Plan the deliverable as an Xcode/SwiftPM project the founder builds on their Mac, with a build-and-test checklist. Planning only, no code yet.
