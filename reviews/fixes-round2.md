# Fixes, round 2 (response to reviews/macos-developer-r2.md)

| Item | Status | What / why |
|---|---|---|
| N-R2-1 window shadow/size | fixed | `captureWindow(_:)` always drops the system shadow (`ignoreShadowsSingleWindow = true`) and sizes output to `SCWindow.frame × pointPixelScale`. Shadow and border are drawn by `decorate`, so the border wraps the window, not shadow padding. Revisit the real shadow once its sizing is measured on a Mac. |
| N-R2-2 blur sigma | fixed | `sigma = max(4, strength × scale)`. |
| N-R2-3 cache thrash | fixed | Cache keyed by annotation id, `(EffectKey, CGImage)` replaced in place; ids no longer in the document are dropped on draw; no size cap/`removeAll`. `liveEffectID` is also set when moving an effect with Select. |
| N-R2-4 / S13 canvas toolbar | fixed (already in place) | The canvas already has a minimum of 760 × 420 pt (`minPt`). The suggested 560 × 240 would still clip the vertical toolbar, whose style row is about 650 pt wide, so 760 × 420 stays. A comment explains why. |
| N-R2-5 Swift 6 Sendable | fixed | `Task { @MainActor in … }` replaces `DispatchQueue.main.async` in `close()`. |
| Nit: border around shadow padding | fixed | Covered by N-R2-1. |
| Nit: `.windowGone` only beeps | fixed | Shows an alert ("Window not captured"). |
| Nit: cursor in window captures | fixed | Window captures use `showsCursor = false`. |
| Nit: canvas aliasing | fixed | `Renderer.smoothFrame` (`.medium`) when the canvas view scale differs from the screen's backing scale. |
| Nit: `pickIndex(of:)` re-lookup | fixed | The view passes the index (`editorDidPickWindow(_:index:)`). |
| Nit: viewScale comment | fixed | Now says "image pixels per view point". |
| Nit: xcodegen needs Local.xcconfig | fixed | Committed `Base.xcconfig` with `#include? "Local.xcconfig"`, and project.yml points at it. |
| Nit: `NSApp.activate()` is async | accepted | A keystroke typed within milliseconds of the hotkey can still go to the previous app. AppKit gives no synchronous activation. |

## Results (Swift 6.0.3, `/tmp/swift-6.0.3-RELEASE-ubuntu22.04/usr/bin`)
- `swift test --package-path Packages/ShareXCore`: 39 tests, 0 failures.
- `swiftc -parse App/Sources/*.swift` (per file): all 14 files parse. This checks syntax only. AppKit, SCK and CI typechecking still needs a Mac build.
