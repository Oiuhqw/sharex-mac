# Validation round: fixes

Sources: `validation-macdev.md`, `validation-eng.md`, `validation-cto.md`. Every BUG and HIGH/MED item is addressed below.
Verification on Linux: the core passes `swift test` (50 tests, 0 failures), and `swiftc -parse` passes on every app file.
The app itself cannot be compiled here (it needs AppKit/ScreenCaptureKit). The first real compile is the prepared macOS CI workflow.

| Item | Fix | Where |
|---|---|---|
| Monitor picker ignored "open editor" | `finishOnPick: mode == .pickMonitor && !openEditor`. The pick only finishes at once when the editor is off. | OverlayController, EditorView |
| Crop drag < 1 pt left crop nil | `Geometry.cropDrag(from:to:in:)` in core; the view uses `if let` for both new crops and resizes. Regression test added. | Geometry, EditorView |
| Tool styles not persisted | `onStyles` callback on close merges each view's `doc.styles`; `CaptureCoordinator.saveStyles` writes to settings only when they changed. Round-trip test. | OverlayController, CaptureCoordinator |
| Text needed two undos | `addText` adds a pending mark outside history; `setText` records one step; an empty abandoned mark is dropped (`commitPendingText` on drag, delete, crop, undo, redo, style). | EditorDocument |
| No surfaces left `busy` stuck | `show()` guards empty surfaces with `close(.cancelled)`. | OverlayController |
| CGRect from CFDictionary | `CGRect(dictionaryRepresentation: b as CFDictionary)`. | ScreenCapture |
| Hotkeys closure isolation | `@escaping @MainActor @Sendable (CaptureStyle) -> Void`. The caller captures `[weak self]` of the `@MainActor` delegate, which is Sendable. | Hotkeys, App.swift |
| KeyboardShortcuts unpinned | `exactVersion: 2.4.0` (latest 2.x; 3.x exists but is a major bump). | project.yml |
| Wrong "ad-hoc" comment, silent missing Local.xcconfig | Comment rewritten. `Base.xcconfig` sets `SHAREX_LOCAL_CONFIG = missing`; Local sets `present`. A pre-build script fails with a clear error unless `CODE_SIGNING_ALLOWED=NO`. | Base.xcconfig, Local.xcconfig.example, project.yml |
| `Main.swift` name | Renamed to `App.swift`. | App/Sources |
| No border colour control | `ColorPicker("Border colour")` bound to `options.borderColor` through sRGB; disabled at width 0. | SettingsView |
| Esc did not cancel countdown | `Countdown.run` returns `Bool`. Local and global Esc monitors are used; the global one only works with Accessibility granted, so clicking the HUD also cancels. Polls every 50 ms. The coordinator uses `guard await Countdown.run(...) else { return }`. | Countdown, CaptureCoordinator |
| Dead Bitmap code | `Bitmap.swift`, `displayTopLeftToCocoa`, `frameIndex`, `polygon(_:contains:)`, `DecorationLayout.borderRect` and their tests were deleted. | core |
| Effect maths in the app | `EffectMath` (blur sigma, pixelate block, pixelate centre, block starts) and `StitchLayout` moved to core, with tests; Renderer and stitch use them. | Geometry, Renderer, CaptureCoordinator |
| Core regression tests | `RegressionTests.swift` (3 classes) covers each fix above and each fuzz finding. | Tests |

Found by fuzzing and fixed (details in `fuzz-report.md`): a JSONDecoder trap on control characters in keys, a stale selection after empty `setText`, and two paths that leaked an empty pending text mark.

Not verified (needs a Mac): the app compile, the Countdown global monitor under Accessibility, the ColorPicker look, and the pre-build script message in Xcode.
