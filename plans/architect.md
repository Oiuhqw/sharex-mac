> Historical planning proposal. See [the current implementation plan](../PLAN.md) for the accepted scope and design.

# ShareX macOS capture: architecture plan

Status: planning only. No code in this repo yet.
Product: native macOS port of ShareX's **capture** side only.
Build constraint: Linux CI cannot compile or run this. Deliverable is an Xcode / SwiftPM project the founder builds on a Mac, plus a build-and-test checklist.
Out of scope (brief): uploads, URL shorteners, destinations.

Principles that shaped this plan: model-the-domain (one typed capture request drives the pipeline), foundational-thinking (types and ScreenCaptureKit adapter before UI chrome).

---

## 1. Feature parity map (ShareX Capture menu)

ShareX Capture menu (Windows reference: MainForm capture dropdown + docs) vs v1 macOS.

| ShareX item | v1 | Notes |
|---|---|---|
| Fullscreen | **IN** | All displays stitched, or virtual desktop bounds via ScreenCaptureKit. |
| Active window | **IN** | Frontmost window; exclude our overlays. Needs Accessibility / window list. |
| Active monitor | **IN** | Display containing the mouse (or focused window; setting chooses). |
| Window menu (pick a window) | **IN** | Submenu or picker of on-screen windows. |
| Monitor menu (pick a display) | **IN** | Submenu of `SCDisplay` / `NSScreen`. |
| Region (rectangle) | **IN** | Full-screen overlay; drag rect; Esc cancel. |
| Region (Light) | **OUT** | Fold into Region; no separate mode. |
| Region (Transparent) | **OUT** | Fold into Region post option if needed later. |
| Last region | **IN** | Replays last successful region rect (per-display normalized). |
| Custom region | **LATER** | Fixed rect in settings; not v1. |
| Freehand / lasso | **IN** | Path selection; rasterize to bitmap with transparent outside (or tight AABB crop; setting). |
| Scrolling capture | **PHASE 2** | Feasible but fragile on macOS (no first-party scroll stitch). Ship stub + design; implement after region/window are solid. |
| Screen recording / GIF | **OUT** | Not capture-still; brief is screenshots. |
| Webpage capture | **OUT** | Needs browser automation. |
| Text capture (OCR) | **OUT** | Post-tool, not capture. |
| Auto capture | **OUT** | Timer loop; nice later. |

### Pre-capture options (chosen before the shot)

| Option | v1 | Notes |
|---|---|---|
| Screenshot delay | **IN** | 0 / 1 / 2 / 3 / 5 s presets + custom ms in settings. Countdown HUD. |
| Show cursor | **IN** | On/off. Composite cursor after capture if API strip omits it. |
| Magnifier / crosshair (region UI) | **IN** | Region and freehand overlays only. |
| Capture shadow / window border | **IN** | Window captures: include window shadow yes/no (default on, ShareX-like). |
| Hide ShareX / our UI during capture | **IN** | Always hide menu-bar panel and overlays before grab (except selection chrome). |

### Post-capture (brief)

| Item | v1 | Notes |
|---|---|---|
| Copy image to clipboard | **MUST** | `NSPasteboard` TIFF/PNG. Primary success criterion. |
| Save to file | **NICE** | Default folder + format in settings. |
| Annotation editor | **NICE / PHASE 2** | Separate window; does not block clipboard copy. |
| Global hotkeys | **NICE** | Carbon / `MASShortcut`-class or AppKit; needs Accessibility input monitoring note. |
| Menu-bar app | **IN** | Primary shell is `LSUIElement` menu-bar agent. |

---

## 2. Design choice (two shapes, one pick)

**Candidate A — Style-first pipeline (chosen).**  
User (or hotkey) picks a `CaptureStyle` up front. A single `CaptureRequest` carries style + pre-options. One `CapturePipeline` runs: prepare → select? → grab → post → clipboard. Selection UI is a strategy per style. Matches ShareX mental model and the brief ("styles chosen BEFORE taking the screenshot").

**Candidate B — Overlay-first toolkit.**  
Always open a fullscreen overlay; tools switch region/window/freehand inside it. Rejected for v1: fights ShareX menu parity, harder hotkey mapping ("capture active window" should not open an overlay).

Synthesis: A. Overlay exists only for styles that need interactive selection (region, freehand, scrolling later).

---

## 3. Core types

Swift sketch (names are the contract; bodies later).

```swift
enum CaptureStyle: String, Codable, CaseIterable {
    case fullscreen
    case activeWindow
    case activeMonitor
    case windowPicker      // user picks from list
    case monitorPicker
    case region
    case lastRegion
    case freehand
    // case scrolling     // Phase 2
}

struct PreCaptureOptions: Codable, Equatable {
    var delay: Duration              // .zero default
    var showCursor: Bool
    var includeWindowShadow: Bool
    var freehandTightCrop: Bool      // vs keep full-display canvas + alpha
}

struct RegionRect: Codable, Equatable {
    var displayID: CGDirectDisplayID
    var rectInDisplay: CGRect        // points, top-left AppKit space
}

struct CaptureRequest: Equatable {
    var style: CaptureStyle
    var options: PreCaptureOptions
    // Filled by picker styles:
    var windowID: CGWindowID?
    var displayID: CGDirectDisplayID?
    var region: RegionRect?
    var freehandPath: [CGPoint]?     // display-local
}

enum CaptureError: Error {
    case cancelled
    case permissionScreenRecording
    case permissionAccessibility
    case noTarget
    case grabFailed(String)
    case pasteboardFailed
}

struct CaptureResult {
    var image: CGImage
    var pixelSize: CGSize
    var style: CaptureStyle
    var sourceRegion: RegionRect?
    var capturedAt: Date
}

protocol ScreenGrabbing: Sendable {
    func grabFullDisplay(_ id: CGDirectDisplayID, showCursor: Bool) async throws -> CGImage
    func grabRect(_ region: RegionRect, showCursor: Bool) async throws -> CGImage
    func grabWindow(_ id: CGWindowID, includeShadow: Bool, showCursor: Bool) async throws -> CGImage
}

protocol ClipboardWriting: Sendable {
    func writeImage(_ image: CGImage) throws
}

protocol WindowCatalog: Sendable {
    func frontmostWindowID() throws -> CGWindowID?
    func listCapturableWindows() throws -> [WindowInfo]
}

struct WindowInfo: Identifiable {
    var id: CGWindowID
    var name: String
    var ownerName: String
    var bounds: CGRect
    var displayID: CGDirectDisplayID
}
```

Domain rule: **invalid states stay unrepresentable.** Picker styles require their ID fields before `run`; the pipeline validates once at the boundary, then strategies trust the request.

---

## 4. Capture pipeline

```text
Menu / Hotkey / CLI test hook
        │
        ▼
  CaptureCoordinator.start(style)
        │  merge AppSettings.preCapture → CaptureRequest
        ▼
  [delay > 0] CountdownHUD → sleep
        ▼
  hideChrome()
        ▼
  SelectionStep? ─────────────────────────────┐
    region / freehand → OverlayController      │
    windowPicker / monitorPicker → list UI     │
    lastRegion → load LastRegionStore          │
    fullscreen / active* → no UI               │
        │                                      │
        ▼                                      │
  ScreenGrabber (ScreenCaptureKit adapter)  ◄──┘
        │
        ▼
  PostProcess
    crop / mask freehand
    composite cursor if needed
    optional shadow already from window API
        │
        ▼
  ClipboardWriter.writeImage  ← MUST succeed for "done"
        │
        ▼
  side effects (async, non-blocking success)
    LastRegionStore.save if region/freehand
    optional FileStore.save
    optional open Annotator
```

### Stage responsibilities

| Stage | Owns | Does not own |
|---|---|---|
| `CaptureCoordinator` | Ordering, cancellation, permission prompts | Pixel math |
| `SelectionStep` | Interactive geometry → fills `CaptureRequest` | Screen bytes |
| `ScreenGrabber` | ScreenCaptureKit / CGWindowList images | Pasteboard |
| `PostProcess` | Crop, mask, cursor composite | Permissions |
| `ClipboardWriter` | `NSPasteboard` types | File I/O |

### Permissions (macOS)

- **Screen Recording** (TCC): required for ScreenCaptureKit. Fail with `permissionScreenRecording` and open System Settings URL.
- **Accessibility**: required for reliable "active window" and some window lists. Fail soft with guidance; still allow fullscreen/monitor/region.
- Build checklist must include granting both on first run.

### Scrolling (Phase 2 sketch only)

Not in v1 pipeline. Later: region select → scroll events to target → frame differencing stitch → same post/clipboard. Mark `CaptureStyle.scrolling` unavailable in UI until implemented.

---

## 5. Settings and per-style options

One plist-backed settings model (UserDefaults or JSON in Application Support). No per-upload profiles (out of scope).

```swift
struct AppSettings: Codable, Equatable {
    var preCapture: PreCaptureOptions
    var activeMonitorBasis: ActiveMonitorBasis  // .mouse | .keyWindow
    var regionMagnifier: Bool
    var regionCrosshair: Bool
    var imageFormatForFile: FileImageFormat     // png | jpeg
    var saveEnabled: Bool
    var saveDirectory: URL?
    var openAnnotatorAfterCapture: Bool
    var hotkeys: [CaptureStyle: HotkeyChord]    // nice-to-have
}

enum ActiveMonitorBasis: String, Codable { case mouse, keyWindow }
enum FileImageFormat: String, Codable { case png, jpeg }
```

**Resolution order:** hotkey/menu style argument → style-specific override (none in v1 except picker targets) → `AppSettings.preCapture` → hardcoded defaults (`delay = 0`, `showCursor = true`, `includeWindowShadow = true`).

Last region is **not** settings; it is session + disk state in `LastRegionStore` (survives relaunch).

---

## 6. Project layout

SwiftPM + thin Xcode wrapper (or Xcode-first with shared packages). Suggested tree the founder creates on the Mac:

```text
ShareXCapture/
  Package.swift                 # or xcodeproj + local packages
  Apps/
    ShareXCapture/              # LSUIElement menu-bar app target
      AppMain.swift
      MenuBarController.swift
      Info.plist                # generated by XcodeGen (LSUIElement etc.)
  Sources/
    CaptureCore/                # pure pipeline + types (testable)
      CaptureStyle.swift
      CaptureRequest.swift
      CapturePipeline.swift
      PostProcess.swift
      LastRegionStore.swift
      AppSettings.swift
    CaptureKit/                 # macOS adapters
      ScreenGrabber+SCKit.swift
      ClipboardWriter+AppKit.swift
      WindowCatalog+CGWindow.swift
      PermissionGate.swift
    CaptureUI/                  # overlays + HUD (AppKit or SwiftUI)
      RegionOverlayController.swift
      FreehandOverlayController.swift
      CountdownHUD.swift
      WindowPicker.swift
    Annotator/                  # Phase 2 / nice; empty target OK in v1
  Tests/
    CaptureCoreTests/           # geometry, last-region, settings round-trip
    # Grabber tests: manual checklist only on Linux CI absence
  Docs/
    BUILD.md                    # Mac build + TCC checklist
    PARITY.md                   # living copy of §1
```

**Module rule:** `CaptureUI` and `CaptureKit` depend on `CaptureCore`. `CaptureCore` depends on nothing AppKit-specific except protocols (inject grabber/clipboard in tests with fakes).

---

## 7. Build-and-test checklist (founder Mac)

1. Xcode 15+ on macOS 14+ (ScreenCaptureKit baseline; verify minimum OS before coding).
2. Open project; resolve packages; build `ShareXCapture`.
3. First launch: grant Screen Recording; retry capture.
4. Grant Accessibility for active-window tests.
5. Manual matrix: each **IN** style → confirm image on clipboard (Paste into Preview).
6. Toggle Show cursor; delay 3 s; Last region after a region capture.
7. Deny Screen Recording once → assert settings deep-link and no crash.
8. (Optional) Save-to-file path; hotkey for region.

Linux agents only edit plans/docs; they never claim a green Mac build.

---

## 8. Implementation order (when coding starts)

1. `CaptureCore` types + settings + fake grabber tests.
2. `ScreenGrabber` fullscreen + monitor + clipboard path (end-to-end must-have).
3. Region overlay + last region.
4. Window catalog + active window + window picker.
5. Freehand.
6. Menu-bar shell + delay HUD + cursor option polish.
7. Nice: save, hotkeys, annotator stub.
8. Phase 2: scrolling.

---

## 9. Open points (not blockers for this plan)

- Exact minimum macOS version (recommend 14 unless founder needs 13).
- Freehand output: transparent canvas vs tight crop (default tight crop).
- Whether window capture uses `SCScreenshotManager` only or also `CGWindowListCreateImage` fallback for shadow fidelity.
