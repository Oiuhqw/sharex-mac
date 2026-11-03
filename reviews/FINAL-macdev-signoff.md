# FINAL macOS developer sign-off (round 4) — 2026-11-03 (UTC+8)

## Verdict: **BLOCK** (one-line fix, then SIGN)

**Blocker B1: the KeyboardShortcuts pin needs a newer Xcode than we document.** `project.yml` pins `exactVersion: 2.4.0`. Its `Package.swift` declares `swift-tools-version:6.1` (checked against the raw file at tag 2.4.0), so it needs **Xcode 16.3 or later**. The README says "Xcode 16+". On Xcode 16.0–16.2, package resolution fails before anything compiles. The `macos-14` CI runner (default Xcode 15.x) fails the same way, and so does the core package (tools 6.0).
Fix, either one:
- (a) pin `exactVersion: 2.3.0` (tools 5.11, works on Xcode 16.0+); or
- (b) keep 2.4.0, change the README to "Xcode 16.3+", and drop `macos-14` from the CI matrix (or select Xcode 16.3+ on it).

If the founder's Xcode is 16.3 or later (likely by Nov 2026), the build is not blocked. Once (a) or (b) is in, this is **SIGN**. Nothing else I found would break the first build or run, or lose data.

## Evidence run here (Linux)
- `swift test --package-path Packages/ShareXCore`: **56 tests, 0 failures**, exit 0.
- `swiftc -parse` on all 14 files in `App/Sources`: **all parse**.
- Force-unwrap grep (`X!`, `try!`) over App and core sources: only `App.swift:46 statusItem: NSStatusItem!` (IUO, set first thing in didFinishLaunching, accepted) and a `try!` inside a comment (Settings.swift:33). **No runtime `!`/`try!` left.**

## Round-4 fix checks
| Check | Result |
|---|---|
| Settings clamping + per-key decode | **PASS.** `AppSettings.init(from:)` decodes every top-level key with `try?` and falls back to that key's default. `CaptureOptions` and `ShapeStyle` have tolerant per-key `init(from:)`. `sanitized()` clamps delay 0…60, border 0…20, colour 0…1 (NaN goes to the default), width 0…40, opacity 0.1…1, font 8…96, strength 0…100. Non-object or invalid JSON is pre-checked with JSONSerialization. Residual (low): `toolStyles` is a non-String-keyed dict, so it encodes as an array, and one unknown future `ShapeKind` drops the whole style map back to defaults. These are preferences, not data. |
| Filename collisions | **PASS.** `uniqueFileName` probes `-2`, `-3`, … `deliver`/`savePNG` run synchronously on the main actor, so two in-app saves can't race. Theoretical TOCTOU only against an outside process writing the same name in the same second; not worth O_EXCL. |
| No-display path | **PASS.** `underMouse` is `first(where:) ?? main ?? screens.first`, else it throws `.noDisplays`. `captureWindow` uses `max(by:)` with a guard that throws `.noDisplays`. `freeze` skips screens with no matching SCDisplay and throws `.noDisplays` if none are left, so an SCShareableContent with no displays gives an error, not a crash. `report` beeps and logs. `OverlayController.show()` with empty surfaces calls `close(.cancelled)` and `busy` is reset. |
| Coordinator ↔ overlay | **PASS.** The coordinator holds `overlay` **strongly** (`private var overlay`), so the overlay lives while it is up. Both `onStyles` and completion closures capture `[weak self]`, so there is no cycle. `endSession`/`.pickedWindow` nil it. Windows have `isReleasedWhenClosed = false`, and their delegate is cleared on close. |
| Force-unwrap fallbacks | **PASS** (see grep). Imaging falls back to DeviceRGB; ToolbarView uses `?? NSImage()` and optional binding; the Pictures dir uses `.first ?? ~/Pictures`. |

## My 4 validation BUGs
1. Monitor picker ignored openEditor: **FIXED**. `finishOnPick` is false when the editor is on (EditorView:243 honours it).
2. Nil crop result passed to `setCropLive`: **FIXED**. `if let r = Geometry.cropDrag(...)` at EditorView:219, and `if let` on resize at :221.
3. toolStyles not persisted: **FIXED**. `close()` merges `doc.styles` and calls `onStyles`, and `saveStyles` writes them when they changed.
4. Text took two undos: **FIXED**. `addText` adds a pending mark outside history; `setText` records one step (core regression tests).

## Matrix misratings
No material misratings among the 36 rows. Nits:
- Rows 12–13 (border, shadow): the drawing is app code; only the layout is tested. They should read "I+T (pixels: Mac)" like row 14.
- Row 28 says width 1–40, but the load clamp is 0–40 (highlighter defaults to 0). This is cosmetic.

## First build / run checklist
- XcodeGen `project.yml`: valid structure. Local package path `Packages/ShareXCore` exists. Info: `LSUIElement: true`, `LSMinimumSystemVersion 14.0`. OK.
- xcconfig: `Base.xcconfig` sets `SHAREX_LOCAL_CONFIG = missing` and then runs `#include? "Local.xcconfig"`. The pre-build script stops a signed build with a clear error until the founder copies `Local.xcconfig.example` and sets a real `DEVELOPMENT_TEAM`. This is intended and is **step 1 for the founder**, not a blocker.
- Signing: Automatic, "Apple Development", hardened runtime. A team is needed (see above). [UNVERIFIED] Xcode's account/provisioning step.
- KeyboardShortcuts: **B1 above.**
- Swift 6 strict concurrency, foreseeable: none that I expect to error.
  - The Countdown local/global monitor closures are formed in a `@MainActor` context, and `Flag` is a MainActor class (Sendable).
  - Hotkeys takes a `@MainActor @Sendable` closure.
  - KeyboardShortcuts 2.x API is MainActor.
  - [UNVERIFIED] Whether the SDK's NSEvent monitor handler annotation lets the local closure mutate `flag` synchronously. If it errors, wrap it as the global one does (`Task { @MainActor in ... }`).
- macOS 14 APIs (`SCScreenshotManager`, `pointPixelScale`, `ignoreShadowsSingleWindow`, `NSApp.activate()`, `NSRunningApplication.activate()`): all are 14.0+, and the deployment target is 14.0, so no `@available` checks are needed.

## Remaining risks (all [UNVERIFIED], Mac-only)
- Screen Recording prompt and grant persistence across rebuilds (needs a stable team signature).
- Hidden main-menu key equivalents in an LSUIElement app.
- Live window capture size with `pointPixelScale`, and stitching across mixed-DPI displays.
- The countdown HUD (`sharingType = .none`) staying out of the frame. The global Esc monitor needs Accessibility; a click on the HUD also cancels.
- Clipboard PNG+TIFF consumers; blur and pixelate hiding text completely.
- The CI smoke test launches the app headless. A menu-bar app should stay up, but this has never run.
