# macOS Developer review: full code (App + ShareXCore)

Status: static review on Linux. There is **no Swift toolchain on the box** (`which swift` is empty), so `swift test` was not run and nothing was compiled. Anything that depends on AppKit/SCK behaviour or exact SDK annotations is marked [UNVERIFIED]; confirm in Xcode 16 / macOS 14 and 15.

**Totals: 4 blockers, 14 should-fix, 10 nits.**

---

## 1. Skeleton (project.yml, Package.swift, signing)

- **should-fix S1. Local package `path: .` (project.yml:8-9).** XcodeGen accepts it, but it makes the repo root (which also holds `App/`, `ShareXMac.xcodeproj` and `.build`) a local package. Xcode then indexes the whole tree as a package, and a project nested inside its own package root is a known source of "package cannot be resolved" or duplicate-reference glitches [UNVERIFIED]. Fix: move the core to `Packages/ShareXCore/` (Package.swift, Sources, Tests) and use
  ```yaml
  packages:
    ShareXCore:
      path: Packages/ShareXCore
  ```
  Linux CI then runs `swift test --package-path Packages/ShareXCore`.
- **should-fix S2. `DEVELOPMENT_TEAM: ""` with Automatic signing (project.yml:42-44).** Automatic signing with no team falls back to "Sign to Run Locally" (ad-hoc). The code identity then changes on every build, so TCC drops the Screen Recording grant and asks again each time. Fix: require a team (read it from a `Local.xcconfig` that is git-ignored), or set `CODE_SIGN_IDENTITY: "Apple Development"` and document it in the README.
- Fine as is: `SWIFT_VERSION 6.0`, `SWIFT_STRICT_CONCURRENCY complete`, hardened runtime with no entitlements (Screen Recording is a TCC grant, not an entitlement), no sandbox, `LSUIElement`, the `KeyboardShortcuts from: 2.0.0` dependency (the product name defaults to the package name), and the `Package.swift` layout (tools 6.0, `.macOS(.v14)`).
- **nit N1.** `Main.swift:12` calls `setActivationPolicy(.accessory)`, but `LSUIElement` already does this. Keep one of them.

## 2. Swift 6 strict concurrency

- **BLOCKER B1. Optional tuple binding does not compile.** At `OverlayController.swift:24` (`if let (id, _) = initialCrop`) and `CaptureCoordinator.swift:64` (`if let (id, crop) = preset, ...`), Swift rejects tuple destructuring in `if let` ("pattern matching in a condition requires the 'case' keyword"). Fix:
  ```swift
  // OverlayController.swift:24
  if let preset = initialCrop, preset.0 != f.displayID { continue }
  // CaptureCoordinator.swift:64
  if case let (id, crop)? = preset, !o.openEditor, let f = frozen.first(where: { $0.displayID == id }) {
  ```
- **BLOCKER B2 [UNVERIFIED on SDK annotation]. `ScreenCapture.windows()` (ScreenCapture.swift:65) and `displayID(of:)` (:33) are nonisolated, but they touch `NSScreen.screens` and `screen.deviceDescription`.** In the macOS 15 SDK, `NSScreen` is `@MainActor`, so under Swift 6 both are errors ("main actor-isolated property … can not be referenced from a nonisolated context"). Fix: isolate the whole enum and drop the per-method attributes:
  ```swift
  @MainActor
  enum ScreenCapture { ... }
  ```
  Every caller is already on the main actor.
- OK: `@preconcurrency import ScreenCaptureKit` together with a `@MainActor` `freeze`. `SCShareableContent`, `SCDisplay` and `SCContentFilter` never leave the main actor, and only `CGImage` is stored, so at most the import downgrades a few diagnostics to warnings. Prefer `try await SCShareableContent.current` (it gives the same result and reads better).
- OK, **nit N2**: `Hotkeys.swift:26`, `Task { @MainActor in capture(style) }`. Under SE-0434 the `@MainActor` function type is Sendable and `style` is Sendable, so this compiles. KeyboardShortcuts 2.x already calls the handler on the main thread, so `MainActor.assumeIsolated { capture(style) }` avoids a run-loop hop. Either one works.
- OK: the `Task { @MainActor in … }` and the `defer { if overlay == nil { busy = false } }` in `CaptureCoordinator.swift:16-21`. Every early return leaves `overlay == nil`, and the completion closure resets `busy`. All `@MainActor` classes (`Renderer`, `EditorView`, `ToolbarView`, `SettingsStore`, `OverlayController`) are consistent with each other.

## 3. ScreenCaptureKit (ScreenCapture.swift)

- OK: `SCContentFilter(display:excludingApplications:exceptingWindows:)` at :48 with our own `SCRunningApplication`, found by PID. When we have no on-screen windows, `ours` is empty, which does no harm.
- OK: `config.width/height = display.width/height * backingScaleFactor` at :51-52. `SCDisplay.width/height` are in points, so this gives full pixels. Also OK: `captureResolution = .best` (14.0), `showsCursor`, and matching `SCDisplay.displayID` against `NSScreenNumber`.
- **should-fix S3. Any `SCShareableContent` error becomes `.noPermission` (:42).** Fix: map only the TCC case, and on macOS 15 handle the recurring "allow to continue capturing?" re-approval the same way:
  ```swift
  catch let e as SCStreamError where e.code == .userDeclined { throw CaptureError.noPermission }
  catch { throw CaptureError.captureFailed(error.localizedDescription) }
  ```
  Use the SCK error, not `CGPreflightScreenCaptureAccess()`, as the source of truth: preflight can stay stale until relaunch (`CaptureCoordinator.swift:25`) [UNVERIFIED].
- **should-fix S4 [UNVERIFIED]. Colour space.** SCK frames come back in the display's colour space (often Display P3), while `Imaging.context` is sRGB, so blur/pixelate patches and the exported PNG shift colour slightly. Fix: `config.colorSpaceName = CGColorSpace.sRGB` (14.0), or build the contexts with `frame.colorSpace ?? Imaging.colorSpace`.
- **nit N3.** The freeze runs sequentially, one display after another (:45-59), so the screens are tens of ms apart. That's acceptable. Parallelising it would need Sendable wrappers, so leave it.
- **nit N4.** Excluding our app also drops our own status-bar icon from the shot. ShareX keeps its tray icon. That's cosmetic, so accept it.
- **nit N5.** `windows()` (:65-80) should also skip `kCGWindowAlpha == 0` windows, which are invisible but still hit-testable in the window picker.

## 4. Overlay windows (OverlayController.swift)

- OK: the `canBecomeKey` override (:5-8), level `.screenSaver` (above the menu bar and Dock), `.canJoinAllSpaces + .fullScreenAuxiliary + .stationary + .ignoresCycle`, `hidesOnDeactivate = false`, `NSApp.activate()` (the macOS 14 API, with no deprecated `ignoringOtherApps`), and key focus going to the screen under the mouse. Showing over a full-screen Space from an accessory app should work [UNVERIFIED, test with a full-screen Safari on a second display].
- **nit N6.** `sharingType = .none` is redundant, because the overlay is never in the frame (we freeze first and exclude our app). On macOS 15, SCK reportedly no longer honours `.none` [UNVERIFIED], so don't rely on it anywhere.
- **BLOCKER B3. Focus never goes back to the previous app.** `show()` activates ShareX, and `close()` never deactivates it. Two consequences: (a) after a capture, the user's app has lost key focus; (b) the next **Active Window** capture finds `frontmostApplication == ShareX`, `windows()` filters our PID out, and the capture just beeps (`ScreenCapture.swift:85-86`). Fix:
  ```swift
  private var previousApp: NSRunningApplication?
  func show() {
      previousApp = NSWorkspace.shared.frontmostApplication
      NSApp.activate()
      ...
  }
  private func close(_ result: EditorResult?) {
      ...
      if let p = previousApp, p != .current { p.activate() } else { NSApp.hide(nil) }
  }
  ```
- **should-fix S5. Teardown happens inside the view's own event handler.** `close()` sets `contentView = nil`, and `CaptureCoordinator` drops the controller, while `EditorView.mouseUp`/`keyDown` is still on the stack. `mouseUp` keeps touching `drag`/`toolbar` after `finish()` returns (EditorView.swift:220-222). AppKit doesn't guarantee to retain the view for the duration of the call [UNVERIFIED, possible use-after-free]. Fix: in `close()`, `orderOut` right away and release everything on the next turn:
  ```swift
  let ws = windows; windows.removeAll()
  for w in ws { w.orderOut(nil) }
  DispatchQueue.main.async { for w in ws { w.contentView = nil } }
  ```
- **should-fix S6. Cursor push/pop is balanced (one push in `show`, one pop in `close`) but fragile.** The NSTextField's I-beam cursor rect and the toolbar controls reset the cursor to the arrow, and with `.activeAlways` tracking the crosshair doesn't come back. Fix: drop the push/pop and declare cursor rects in `EditorView`:
  ```swift
  override func resetCursorRects() {
      addCursorRect(bounds, cursor: .crosshair)
      if toolbar.superview != nil { addCursorRect(toolbar.frame, cursor: .arrow) }
  }
  ```
  Call `window?.invalidateCursorRects(for: self)` after `layoutToolbar()`.
- **should-fix S7. Multi-screen state.** `editorDidActivate` (:74-79) only resets other screens that are still *selecting*. If screen A is in editing and the user clicks screen B, both screens show a toolbar and Enter only finishes the key one. Fix: once any view enters editing, set `ignoresMouseEvents = true` on the other overlays (or orderOut them).

## 5. Coordinates

- OK: `ScreenCapture.windows()` flips CG top-left global bounds with `NSScreen.screens.first.frame.height` (:69, :77). The primary screen's frame origin is (0,0), so `height == maxY`, which is correct.
- OK: `Geometry.cocoaToDisplayTopLeft` / `displayTopLeftToCocoa` (Geometry.swift:16-23) are exact inverses, and the `stitch` call that uses the union as `screenFrame` correctly gives each display's top-left offset in the virtual desktop.
- OK: `NSScreen.main` appears only as a fallback when no screen contains the mouse (`CaptureCoordinator.swift:34`, `Countdown.swift:19`). It is never used for a flip.
- **nit N7.** The plan asked for distinct point/pixel types. `CGRect` is still used for all three spaces, and the meaning lives only in comments (Geometry.swift:5-8). Wrap them later (`DisplayRect`, `PixelRect`) if bugs show up.

## 6. Rendering and export (Renderer.swift, Export.swift, Imaging.swift)

- OK: `Imaging.context(flipped:)` followed by `translate(-area.min)` and then `scale(s)` (Export.swift:13-15) gives y-down frame points, so the order is correct. `drawUpright` (Imaging.swift:38-44) maps `rect` y-down correctly. The flipped `NSGraphicsContext` for text (Renderer.swift:89-94) is correct. The shadow offset is in base space, so `-offset` drops the shadow downwards (Export.swift:34), which is also correct.
- OK: **highlighter multiply** (Renderer.swift:45-48). It blends against the frame that was drawn into the same context, both on screen and in export. **nit N8:** drop the `max(opacity, 0.2)` floor and use the style opacity, because multiply already keeps text legible.
- OK: lasso export. The clip runs before the frame draw, and the context starts zeroed and premultiplied, so pixels outside the lasso are transparent. PNG and TIFF both come from the same `NSBitmapImageRep(cgImage:)`, so alpha is kept in both.
- **BLOCKER B4. Blur/pixelate cache and CPU cost (Renderer.swift:98-113, Bitmap.swift:50-78).** The cache is keyed by the pixel rect, so **every `mouseDragged`** while drawing or resizing a blur misses and recomputes: a CGImage→Bitmap copy, then 6 box passes in Swift `[Int]` arrays (4 per-pixel inner loops). A full-screen region at 6K is about 20 M px × 6 passes, roughly 0.5-2 s per event even in Release, so the UI freezes. Memory is worse: up to 65 cached patches of up to ~80 MB each (6016×3384×4), several GB, before the cache is cleared. Fix: render effects with Core Image from one cached `CIImage` of the frame, and keep a small cache:
  ```swift
  private let ciContext = CIContext(options: [.cacheIntermediates: false])
  private lazy var ciFrame = CIImage(cgImage: frame)
  private func effectPatch(_ a: Annotation) -> (image: CGImage, rect: CGRect)? {
      let px = Geometry.pixelRect(a.rect, scale: scale)
      guard let clipped = Geometry.clamp(px, to: CGRect(x: 0, y: 0, width: frame.width, height: frame.height)) else { return nil }
      let key = "\(a.kind)|\(clipped)|\(a.style.strength)"
      if let hit = effectCache[key] { return (hit, rect(for: clipped)) }
      // CI is y-up: convert the top-left pixel rect.
      let ciRect = CGRect(x: clipped.minX, y: CGFloat(frame.height) - clipped.maxY, width: clipped.width, height: clipped.height)
      let src = ciFrame.cropped(to: ciRect).clampedToExtent()   // samples only inside the region
      let s = a.style.strength * scale
      let out: CIImage = a.kind == .blur
          ? src.applyingGaussianBlur(sigma: max(1, s / 2))
          : src.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(2, s),
                                                         kCIInputCenterKey: CIVector(x: ciRect.minX, y: ciRect.minY)])
      guard let cg = ciContext.createCGImage(out.cropped(to: ciRect), from: ciRect) else { return nil }
      if effectCache.count >= 8 { effectCache.removeAll() }
      effectCache[key] = cg
      return (cg, rect(for: clipped))
  }
  ```
  Also, while a drag is in progress, draw only the live patch for the annotation being dragged and keep cache entries just for committed annotations. Keep `Bitmap.blur/pixelate` as the tested reference, and add a test that the CI output differs from the source everywhere inside the rect (so the redaction really changes every pixel) [UNVERIFIED perf numbers; profile with Instruments].
- **should-fix S8.** The drawn drop shadow's `shadowBlur`/`shadowOffset` are fixed in pixels (Capture.swift:68-69), so at 2x the shadow is half the size. Multiply both by `scale` in `DecorationLayout` and `decorate`.
- **nit N9.** `copyToClipboard`'s `pb.changeCount != before` (Export.swift:59) is always true, because `clearContents()` already bumps it. Return `pb.writeObjects([item])` alone. The single `NSPasteboardItem` with `.png` + `.tiff` and `rep.size` in points is correct.
- **nit N10.** `savePNG` (Export.swift:68-70) writes no DPI, so a 2x file opens at double size in Preview. Pass `[kCGImagePropertyDPIWidth: 72*scale, kCGImagePropertyDPIHeight: 72*scale]` to `CGImageDestinationAddImage`.

## 7. Editor input (EditorView.swift, ToolbarView.swift)

- **should-fix S9. There is no main menu, so ⌘C/⌘V/⌘X/⌘A/⌘Z do nothing inside the text field.** An accessory app has `NSApp.mainMenu == nil`, and the field editor's standard edit actions are reached through menu key equivalents. Fix (in `applicationDidFinishLaunching`):
  ```swift
  let main = NSMenu(); let editItem = NSMenuItem(); main.addItem(editItem)
  let edit = NSMenu(title: "Edit")
  edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
  edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
  edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
  edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
  edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
  editItem.submenu = edit; NSApp.mainMenu = main
  ```
  Then make `EditorView` respond to `copy(_:)` (finish) and `undo:`/`redo:` so the editor's ⌘C/⌘Z keep working through the menu.
- **should-fix S10. Return and Esc inside the text field.** Esc goes to the field editor (`complete:`/`cancelOperation:`), not to `EditorView.keyDown`, so Esc while typing does nothing useful. Fix in the `NSTextFieldDelegate`:
  ```swift
  func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
      switch sel {
      case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.insertNewline(_:)): commitText(); return true
      default: return false
      }
  }
  ```
  `controlTextDidEndEditing` → `commitText` re-entrancy is safe because of the `textField == nil` guard.
- **should-fix S11. Clicks on the toolbar background fall through.** `NSVisualEffectView` passes `mouseDown` it doesn't handle up the responder chain to `EditorView`, so clicking between toolbar buttons starts a shape or crop under the toolbar. Fix in `ToolbarView`:
  ```swift
  override func mouseDown(with e: NSEvent) {}
  override func mouseDragged(with e: NSEvent) {}
  override func mouseUp(with e: NSEvent) {}
  override func rightMouseDown(with e: NSEvent) {}
  ```
- OK: first responder after toolbar clicks. Every toolbar action goes through `setTool`/`changeStyle`/`undo` → `refocus()`. `colorPicked` with no style target returns early without refocusing, but buttons don't take focus unless Full Keyboard Access is on, so that's acceptable.
- **should-fix S12. Right-click with annotations cancels the whole capture and throws away the work** (EditorView.swift:225-234). ShareX only cancels when there's nothing to lose. Fix: when `!doc.annotations.isEmpty`, select or delete the mark under the cursor, or do nothing, rather than calling `cancel()`.
- OK: double-click on empty space finishes (EditorView.swift:149). The degenerate shape from the first click is removed in `endDrag` (EditorDocument.swift:75-79). Steps are never degenerate, so a double-click with the Step tool places a step and then finishes. That's acceptable.
- **should-fix S13.** The toolbar is about 1000 pt wide (13 segments × 28 + palette + 3 sliders × 70 + buttons), so `layoutToolbar` (:248-256) overflows on a 1024-1280 pt screen. Wrap it onto two rows or drop the sliders into a popover when `fittingSize.width > bounds.width - 8`.

## 8. Known gaps

- **Occluded window capture. Agree, with a caveat.** For **Active Window** and a **Window picker click**, capture that window live with `SCContentFilter(desktopIndependentWindow: scWindow)`: `config.width/height = scWindow.frame.size * scale`, `config.ignoreShadowsSingleWindow = !options.shadow` (14.0), plus `shouldBeOpaque`/`ignoreGlobalClipSingleWindow` [UNVERIFIED names]. Then open the editor on that image in a plain editor window (or in the overlay on the window's display with the image as the frame). Use it even when an annotation is needed, so the window looks the same whether or not you annotate. Keep freeze-frame for Region and Freehand clicks that snap to a window, because there the user has picked pixels. With the shadow on, the image is larger than `SCWindow.frame`, so size the border/crop from the image (see the plan review, item 8).
- **Multi-display fullscreen skips the editor. Agree for v1.** When `openEditor` is on, open the stitched image in a normal resizable **editor window** that is scaled to fit, rather than the per-display overlay. That same window is needed for occluded window captures and for "open image in editor", so build it once.
- **should-fix S14. Region spanning displays.** You can't drag a region across two screens, because each overlay clamps to its own bounds. ShareX allows it. v1 can accept this, but document it. A later option is to cut the region out of the max-scale stitch.

### Missing ShareX screenshot features
Scrolling capture; auto/interval capture; screen colour picker and ruler; pin to screen; "capture with menu" snapping to child UI elements (needs AX); OCR (Vision `VNRecognizeTextRequest`); more annotation tools (rounded rectangle, triangle, speech balloon, magnify, sticker/image insert, cursor stamp, smart eraser, cut-out); image effects beyond border and shadow (watermark, resize, rounded corners); after-capture tasks (Save as…, open in editor from file, upload, print, show in Finder notification); file-name patterns; capture history; open an existing image in the editor; copy the file path.

---

## Plan issues from reviews/macdev-plan.md

| # | Issue | Status | Evidence |
|---|---|---|---|
| 1 | `canBecomeKey` on overlay | **landed** | `OverlayController.swift:5-8` overrides `canBecomeKey`/`canBecomeMain`; `:58-60` calls `makeKeyAndOrderFront` + `makeFirstResponder`; `NSApp.activate()` at `:54`. Focus *return* is missing (B3). |
| 2 | One coordinate model flipped against primary screen | **partial** | The flip uses `NSScreen.screens.first` (`ScreenCapture.swift:69,77`); there is one converter pair (`Geometry.swift:16-23`); `NSScreen.main` appears only as a fallback. The distinct point/pixel **types** were not added: everything is `CGRect`, with the space noted only in comments. |
| 3 | Mixed-DPI stitch rule | **landed** | `CaptureCoordinator.swift:95-107` uses the max `backingScaleFactor` for the canvas, places each display at its global top-left, and upscales 1x frames with `.high` interpolation. Crops can't span displays, so the ×2 shift can't happen (see S14). |
| 4 | Freeze-frame vs live window capture | **landed (decided: freeze-frame everywhere)** | `ScreenCapture.swift:31`: "SCK only… captures whole displays; every style crops these". Window modes crop the frozen display (`CaptureCoordinator.swift:42-47`, `OverlayController.swift:30-31`). The cost is occluded windows, which REVIEW-REQUEST §8 already tracks; see the recommendation above. |
| 5 | `NSScreenCaptureUsageDescription` removed | **landed (code); stale docs** | `grep -rn` finds it in no plist, no `project.yml` info property and no Swift file. It survives only in `plans/architect.md:251` and `plans/cto.md:116`. Delete those lines so nobody adds it back. |
