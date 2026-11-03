# Final feature matrix — ShareX for macOS

Validated 2026-11-03 (UTC+8) on Linux. The core (`Packages/ShareXCore`) is built, unit-tested and fuzzed here.
The app (`App/Sources`, AppKit + ScreenCaptureKit) can only be parse-checked on Linux, so every app path below
was traced by reading the code. **IMPLEMENTED (app-only)** means the code path exists end to end but has not
run, because that needs a Mac.

Legend: **I+T** = implemented, with its logic in the core under unit + fuzz tests · **APP** = implemented, app-only, needs a Mac · PARTIAL · MISSING

| # | Feature | Entry (menu / hotkey) | Handler → core → output | Status |
|---|---|---|---|---|
| 1 | Region capture | Menu item (App.swift:60–75, 114–118); ⌃⇧1 (Hotkeys.swift:7) | CaptureCoordinator.capture:13 → run:23 → freeze:57 → overlay (rectangle select, snap EditorView mouseUp ~231) → deliver:144 | APP |
| 2 | Window picker | Menu; ⌃⇧2 (Hotkeys:8) | overlay pickWindow (EditorView mouseUp ~238) → editOrDeliver:99 → ScreenCapture.captureWindow | APP |
| 3 | Fullscreen (all displays) | Menu; ⌃⇧3 (Hotkeys:9) | run → stitch:157 (core `StitchLayout`, fuzzed) | APP |
| 4 | Active window | Menu; recorder in Settings (Hotkeys:12, no default) | run case .activeWindow:42 → ScreenCapture.activeWindow | APP |
| 5 | Active monitor | Menu; ⌃⇧4 (Hotkeys:10) | run case .activeMonitor:47 (screen under mouse) | APP |
| 6 | Monitor picker | Menu; recorder (Hotkeys:13) | overlay pickMonitor (EditorView mouseUp ~240) | APP |
| 7 | Freehand / lasso | Menu; ⌃⇧5 (Hotkeys:11) | overlay lasso (EditorView ~235) → Export.flatten lasso clip:10 | APP |
| 8 | Last region | Menu; recorder (Hotkeys:14) | run case .lastRegion:49 → core `LastRegion.resolve` (tested) | APP |
| 9 | Delay | "Before capture" submenu (App:82–89); Settings tab | Countdown.run (CaptureCoordinator:31); Esc or a click cancels; clamped to 0…60 on load (new) | APP |
| 10 | Show cursor | submenu (App:90) | `freeze(showCursor:)` :57 | APP |
| 11 | Magnifier | submenu (App:91) | EditorView crosshair/magnifier (~450–484), rectangle and lasso modes only | APP |
| 12 | Border + colour | submenu toggle (App:92/124); Settings stepper 0–20 + ColorPicker | Export.decorate:25 → core `DecorationLayout` (tested), now sanitized | I+T |
| 13 | Shadow | submenu (App:93) | Export.decorate → `DecorationLayout` | I+T |
| 14 | Rectangle | toolbar / `r` | EditorView editingMouseDown → `EditorDocument.addShape/extendShape` → Renderer:42 | I+T (pixels: Mac) |
| 15 | Ellipse | `e` | same → Renderer:44 | I+T |
| 16 | Line | `l` | → Renderer:46 | I+T |
| 17 | Arrow | `a` | → Renderer:48 | I+T |
| 18 | Highlighter | `h` | → Renderer:53 (multiply blend) | I+T |
| 19 | Blur | `b` | → Renderer effectPatch:107 (`EffectMath.blurSigma`, fuzzed) | I+T |
| 20 | Pixelate | `p` | → effectPatch (`pixelateBlock`, `pixelateCenter`) | I+T |
| 21 | Spotlight | `s` | → Renderer:64 | I+T |
| 22 | Pen | `f` | → Renderer:57 | I+T |
| 23 | Text (+ background when filled) | `t` | addText / setText (EditorView ~341–376) → Renderer:70, 89 | I+T |
| 24 | Step markers | `i` | → Renderer:72, `stepNumber(of:)` | I+T |
| 25 | Crop | `c` | cropNew / cropResize (EditorView ~219) → `Geometry.cropDrag`, `setCropLive` + endDrag | I+T |
| 26 | Select / move / resize / delete | `v`, drag, handles, arrow-key nudge, ⌫ / right-click | hitTest, move, resize, deleteSelected | I+T |
| 27 | Colour | toolbar palette | `applyStyle` → per-tool style, saved via saveStyles:115 | I+T |
| 28 | Width / font size | slider 1–40 (8–96 for text) | applyStyle; clamped on load | I+T |
| 29 | Fill | checkbox (rectangle, ellipse, text) | applyStyle `filled` | I+T |
| 30 | Opacity | slider 0.1–1 | applyStyle; clamped on load | I+T |
| 31 | Undo / redo | ⌘Z / ⇧⌘Z, toolbar (EditorView:113–118) | `UndoStack` limit 200 (fuzzed undo-all invariant) | I+T |
| 32 | Enter → clipboard PNG+TIFF | Return / keypad Enter (EditorView:310), double-click, Done | finish:136 → Export.flatten → decorate → copyToClipboard:49 (one item with .png and .tiff, :57–58) | APP |
| 33 | Esc cancels | Esc (EditorView:309), Countdown, toolbar ✕ | cancel:121 → editorDidCancel; overlay closes with nothing copied | APP |
| 34 | Save to file | Settings → General | deliver → savePNG:63 (`AppSettings.uniqueFileName`, tested); a failed save now beeps and logs | APP |
| 35 | Settings persistence | Settings window, menu toggles | SettingsStore `settings.v1` init:10 / update:12 → `AppSettings.decode/encoded` (tolerant, sanitized, fuzzed) | I+T |
| 36 | Hotkeys | KeyboardShortcuts 2.4.0 recorders for all 8 styles | Hotkeys.register:24 (onKeyUp) → coordinator.capture | APP |

**Counts:** 36 features. I+T 21 · APP 15 · PARTIAL 0 · MISSING 0.

Notes:
- The tool's model and undo are tested in the core; how each mark looks on screen still needs a check on a Mac.
- Rows 4, 6 and 8 have no default hotkey (same as ShareX). You can set one in Settings → Hotkeys.
- With a lasso, a later crop keeps the lasso path. This is accepted.
- Scrolling capture, GIF and video recording, and upload are out of scope, as you asked.

## What to check by hand on a Mac (none of this runs on Linux)
1. The Screen Recording permission prompt, then each of the 8 styles from the menu and from ⌃⇧1–5.
2. Enter puts the image in Preview → File → New from Clipboard (PNG) and in a TIFF-only app. Esc copies nothing.
3. Blur and pixelate fully hide text. The pixelate grid starts at the region's top-left (CIPixellate centre semantics).
4. Multi-display fullscreen stitch, including mixed Retina and non-Retina displays.
5. Saving twice in the same second gives `…-2.png`. Pointing it at a read-only folder beeps.
