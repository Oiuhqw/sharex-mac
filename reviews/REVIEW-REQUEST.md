# Review request: macOS Developer

Please review `/workspace/sharex-mac`, which is a full port of the ShareX screenshot and annotation features. Write your feedback to `reviews/macos-developer.md`.

**Scope.** Everything was written on Linux, and only `ShareXCore` was compiled and tested there. Nothing in `App/Sources` has been compiled. Please mark each finding **blocker / should-fix / nit**, and include the exact fix where you can.

1. **Skeleton:** `project.yml`, `Packages/ShareXCore/Package.swift`, the target layout and the signing settings. Check that the XcodeGen local package (now `path: Packages/ShareXCore`, fixed in round 1) is valid.
2. **Swift 6 strict concurrency:**
   - The `@MainActor` classes, plus `@preconcurrency import ScreenCaptureKit` in `ScreenCapture.freeze`.
   - The `KeyboardShortcuts.onKeyUp` closure wrapping in `Hotkeys.swift`, and `Task` usage in `CaptureCoordinator`.
3. **ScreenCaptureKit (`ScreenCapture.swift`):**
   - The `SCContentFilter(display:excludingApplications:exceptingWindows:)` call, and excluding our own app.
   - The `SCStreamConfiguration` width/height in pixels, `showsCursor`, and the full-resolution output.
   - Matching NSScreen to SCDisplay by `CGDirectDisplayID`.
4. **Overlay windows (`OverlayController.swift`):**
   - Level `.screenSaver`, `sharingType = .none`, and the collection behaviour.
   - Key focus across several screens, behaviour over full-screen Spaces, and the cursor push/pop.
5. **Coordinates:** the flipped view in display top-left points ↔ Cocoa global ↔ CGWindowList (top-left global, origin at the primary display), in `ScreenCapture.windows()` and `Geometry.cocoaToDisplayTopLeft`.
6. **Rendering and export (`Renderer.swift`, `Export.swift`):**
   - Check the CGContext flipping and `Imaging.drawUpright`.
   - Highlighter: confirm the multiply blend.
   - Blur/pixelate: is the patch cache right, and is CPU blur performance acceptable at 6K?
   - Clipboard: one NSPasteboardItem carrying PNG+TIFF, with the rep size in points.
7. **Editor input (`EditorView.swift`, `ToolbarView.swift`):**
   - Inline NSTextField editing, keyDown handling, and first responder after toolbar clicks.
   - Double-click and right-click behaviour.
8. **Known gaps. Please agree or suggest an approach:**
   - Occluded window capture. Should window styles use `SCContentFilter(desktopIndependentWindow:)` when no annotation is needed?
   - Multi-display fullscreen skips the editor.
   - Any ShareX screenshot feature that is missing.
