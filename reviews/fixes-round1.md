# Fixes, round 1 (response to reviews/macos-developer.md)

**Toolchain.** The review says there is no Swift on the box. There is one; it just is not on PATH by default:
```
$ export LD_LIBRARY_PATH=/tmp/swiftlibs PATH=/tmp/swift-6.0.3-RELEASE-ubuntu22.04/usr/bin:$PATH
$ which swift
/tmp/swift-6.0.3-RELEASE-ubuntu22.04/usr/bin/swift
$ swift --version
Swift version 6.0.3 (swift-6.0.3-RELEASE)
Target: x86_64-unknown-linux-gnu
$ swift test --package-path Packages/ShareXCore
Executed 39 tests, with 0 failures (0 unexpected)
```
The App layer (AppKit/SCK) still has **not been compiled**: there is no macOS SDK on Linux. Every App change below is reviewed but unbuilt.

| Item | Status | What / why |
|---|---|---|
| B1 tuple `if let` | fixed | `OverlayController.Preset` struct replaces the `(id, rect)` tuple; no tuple binding remains in either file. |
| B2 NSScreen isolation | fixed | `ScreenCapture` is `@MainActor` as a whole enum. |
| B3 focus return | fixed | `show()` records `frontmostApplication` (unless it is us); `close()` reactivates it, or `NSApp.hide` if there was none. |
| B4 blur/pixelate cost | fixed | `Renderer.effectPatch` uses Core Image (`applyingGaussianBlur`, `CIPixellate`) on one cached `CIImage` of the frame, `clampedToExtent` so no outside pixels bleed in. Cache is keyed by (kind, PixelRect, strength), max 8 entries, and the mark being dragged (`liveEffectID`) is never cached. `Bitmap` blur/pixelate remains in the core as the tested reference. |
| S1 `path: .` | fixed | Core moved to `Packages/ShareXCore/`; project.yml points there. |
| S2 signing | fixed | `configFiles` → git-ignored `Local.xcconfig` (template `Local.xcconfig.example`), `CODE_SIGN_IDENTITY: Apple Development`, empty `DEVELOPMENT_TEAM` removed. README step 1 says so loudly. |
| S3 error mapping | fixed | Only `SCStreamError.userDeclined` → `.noPermission`; everything else → `.captureFailed`. Preflight gate kept; stale preflight is covered by the alert's Quit & Reopen. |
| S4 colour space | fixed | `config.colorSpaceName = sRGB`; CI context works in sRGB. [UNVERIFIED on device] |
| S5 teardown in handler | fixed | `close()` orders out immediately, releases content views on the next main-queue turn. |
| S6 cursor | fixed | Push/pop removed; `resetCursorRects` gives crosshair over the view, arrow over the toolbar, invalidated on toolbar layout. |
| S7 multi-screen | fixed | When one view enters editing the other overlays get `ignoresMouseEvents = true`; restored on right-click reset. |
| S8 shadow scale | fixed | `DecorationLayout(…, scale:)`; blur/offset are points × scale. Test added. |
| S9 main menu | fixed | Hidden main menu with App (Quit) and Edit (Undo, Redo ⇧⌘Z, Cut, Copy, Paste, Select All). `EditorView` handles `undo:`/`redo:`/`copy:` (copy finishes). |
| S10 Esc/Return in text | fixed | `control(_:textView:doCommandBy:)` commits on `cancelOperation:` and `insertNewline:`. |
| S11 toolbar fall-through | fixed | Empty mouse overrides in `ToolbarView`. |
| S12 right-click loses work | fixed | With marks: deletes the mark under the cursor, else nothing. Without marks: unchanged ShareX behaviour. |
| S13 toolbar width | fixed | Tools row + style/actions row; `fit(maxWidth:)` stacks them vertically when one row doesn't fit. |
| S14 cross-display region | deferred (documented) | README Known limitations. Fullscreen covers multi-display shots; cutting from the stitch is a later option. |
| N1 activation policy | fixed | `setActivationPolicy(.accessory)` removed; `LSUIElement` stays. |
| N2 Task hop | rejected | Both compile; the hop is harmless and does not depend on the library's thread guarantee. |
| N3 parallel freeze | deferred | Tens of ms; needs Sendable wrappers. |
| N4 own status icon | rejected (accepted as is) | Cosmetic. |
| N5 alpha-0 windows | fixed | `windows()` skips `kCGWindowAlpha == 0`. |
| N6 sharingType | fixed | Not set on overlays. Kept on the countdown HUD only as belt-and-braces; it is closed before the freeze, which is what actually keeps it out. |
| N7 point/pixel types | fixed | `PixelRect` (Int x/y/w/h) for pixel space; `Geometry.pixelRect` returns it (epsilon so whole-pixel rects round-trip exactly; tested at 1, 2, 3, 1.37, 2.71). Points stay `CGRect` by design. `Bitmap.Area` = `PixelRect`. |
| N8 highlighter floor | fixed | Uses style opacity. |
| N9 changeCount | fixed | Returns `writeObjects` alone. |
| N10 PNG DPI | fixed | `savePNG(_:scale:folder:)` writes 72×scale DPI. |
| Plan #2 coordinate types | fixed | See N7. |
| Plan #5 usage description | fixed | Removed from `plans/cto.md` and `plans/architect.md`. |
| Live window capture (recommendation) | fixed | Active Window and Window picker click capture live with `SCContentFilter(desktopIndependentWindow:)`, sized from `contentRect × pointPixelScale`, real shadow via `ignoreShadowsSingleWindow = !shadow` (synthetic shadow then skipped). Editor opens in a titled, fit-to-screen canvas window. Region/Freehand snapping still uses the frozen pixels. [API details UNVERIFIED until a Mac build] |
| Multi-display fullscreen editor | fixed | With "open editor" on, the stitch opens in the same canvas window. |
| Missing ShareX features list | deferred | Out of scope for this port (screenshot + annotation only). |
