# ShareX macOS (capture) — Head of Engineering plan

Planning only. Deliverable is an Xcode / SwiftPM project the founder builds on their Mac. Our Linux box cannot compile or run this.

## 1. Module breakdown

| Module | Responsibility | Primary APIs |
|---|---|---|
| **AppShell** | Menu-bar (optional early) or windowed host, lifecycle, permissions prompts | `NSApplication`, `LSUIElement` / menu-bar extras later |
| **CaptureIntent** | UI + model for choosing style **before** capture: region, window, fullscreen, active monitor, freehand/lasso; options: delay, cursor on/off, magnifier/crosshair, border/shadow | SwiftUI or AppKit panels |
| **Hotkeys** (nice) | Global shortcuts → CaptureIntent | `MASShortcut` or `CGEvent` tap / Carbon `RegisterEventHotKey` |
| **RegionPicker** | Full-screen overlay: crosshair, magnifier, rubber-band rect, Esc cancel | Transparent `NSWindow` / `NSPanel` at `.screenSaver` level |
| **WindowPicker** | Hover-highlight windows; click to select | `CGWindowListCopyWindowInfo`, ScreenCaptureKit window filter |
| **FreehandPicker** | Lasso path → mask bitmap | Overlay + Core Graphics path |
| **CaptureEngine** | Execute capture after intent + optional delay | **ScreenCaptureKit** (`SCShareableContent`, `SCScreenshotManager` / stream single frame); fallback notes for older macOS if needed |
| **ScrollingCapture** | Stitch scroll frames if feasible | SCK + accessibility scroll, or defer if fragile |
| **ImagePipeline** | Cursor composite, crop, border/shadow, scale/color space | Core Image / Core Graphics |
| **Clipboard** | Put PNG (and optionally TIFF) on pasteboard | `NSPasteboard`, `NSImage` / `CGImage` |
| **AnnotationEditor** (nice) | Post-capture draw/text/arrows | Separate window; can ship after MVP |
| **Export** (nice) | Save to file | `NSSavePanel` |
| **Permissions** | Screen Recording + Accessibility (if scroll/window helpers need it) | `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`; guide to System Settings |

**Dependency rule:** CaptureIntent → (Picker) → CaptureEngine → ImagePipeline → Clipboard. No network modules.

**Suggested project shape:** `ShareXCapture.xcodeproj` (macOS app) + optional `ShareXCaptureCore` SwiftPM library for engine/pipeline (easier unit tests of pure image logic).

**Target OS:** macOS 14+ preferred (ScreenCaptureKit screenshot APIs are saner); document 13.x gaps if founder needs them.

## 2. Milestones (in order)

1. **M0 — Skeleton + permissions** — Empty app, Screen Recording prompt, fail loudly if denied.
2. **M1 — Fullscreen + active monitor → clipboard** — No picker UI; proves CaptureEngine + Clipboard + color space.
3. **M2 — CaptureIntent panel** — Choose style + delay + cursor on/off before arming capture.
4. **M3 — Region picker** — Overlay, crosshair, magnifier, rubber-band; Esc cancels; result → clipboard.
5. **M4 — Window capture** — Window list + highlight picker → capture that window’s bounds (respect on-screen geometry).
6. **M5 — Pre-capture polish** — Cursor composite on/off, border/shadow presets, timer countdown UI.
7. **M6 — Freehand/lasso** — Path mask; transparent outside selection.
8. **M7 — Scrolling capture spike** — Time-box 1–2 weeks; ship or cut based on reliability on founder’s apps (Safari, Notes, Xcode).
9. **M8 — Nice path** — Hotkeys, menu-bar mode, save to file, annotation editor (priority order with founder).

Do not start M8 until M3–M5 pass the founder checklist. Do not block MVP on M7.

## 3. Minimum feature set (working example)

A **working example** means the founder can:

1. Launch the app and grant Screen Recording.
2. Open CaptureIntent and pick **Region** or **Fullscreen** or **Active monitor**.
3. Optionally set a **delay** and **cursor on/off**.
4. Complete the capture (region overlay works end-to-end).
5. **Paste into Preview / Slack / Notes** and see a correct image (resolution, no washed colors, expected crop).

**In:** CaptureIntent, RegionPicker, fullscreen, active monitor, delay, cursor toggle, CaptureEngine (SCK), ImagePipeline basics, Clipboard.  
**Out of working example:** freehand, scrolling, annotation, hotkeys, menu-bar, save dialog, uploads (forever out of scope).

## 4. Founder test checklist (run on their Mac)

Build: open Xcode project → scheme `ShareXCapture` → Run (Apple Silicon or Intel as available).

### Permissions
- [ ] First launch prompts for Screen Recording; denying shows a clear in-app message with link path to System Settings → Privacy & Security → Screen Recording.
- [ ] After granting and relaunching, capture succeeds.

### Fullscreen / monitor
- [ ] Fullscreen capture pastes an image matching the display layout (multi-monitor: all screens or documented behavior).
- [ ] Active monitor capture matches the screen under the mouse (or focused screen — document which).

### Region
- [ ] Overlay covers the target display; other apps dim or remain visible per design.
- [ ] Crosshair + magnifier track the cursor.
- [ ] Drag selects a rectangle; release captures; Esc cancels with nothing new on the clipboard.
- [ ] Very small region and near-full-screen region both work.

### Intent-before-capture
- [ ] Style and options are chosen **before** the overlay/capture runs (ShareX order).
- [ ] Delay 3s: countdown then capture; moving windows during delay is OK.
- [ ] Cursor on: pointer visible in shot; cursor off: absent.

### Clipboard
- [ ] Paste into Preview, Notes, and one Electron app (e.g. Slack/Figma).
- [ ] Image is PNG-class sharpness; not a zero-byte or stale previous screenshot.
- [ ] Capturing twice updates pasteboard to the latest image.

### Window (once M4 ships)
- [ ] Hover highlights the correct window; click captures that window only.
- [ ] Capturing a partially off-screen window matches visible bounds or documented behavior.

### Freehand / scroll (once shipped)
- [ ] Lasso produces transparent exterior when pasted into a viewer that supports alpha.
- [ ] Scroll capture: stitch quality on Safari long page — accept or file bugs; flaky = keep behind flag.

### Non-goals check
- [ ] No upload UI or network destination settings present.

## 5. Top risks

1. **Screen Recording permission + TCC** — Silent black frames if not granted or if the binary’s code signature / Team ID changes; notarization and stable bundle ID matter before sharing builds.
2. **ScreenCaptureKit vs legacy CGDisplayStream/CGWindowList** — API surface differs by OS version; picking only old APIs limits future; picking only new APIs drops older Macs. Pin a minimum OS early.
3. **Multi-display coordinates** — Backing scale (`backingScaleFactor`), menu bar, and mismatched picker vs capture rects cause off-by-retina crops. Need one coordinate space convention in CaptureEngine.
4. **Clipboard consumers disagree** — Some apps prefer TIFF, some PNG; put both representations on `NSPasteboard` if Preview works but Slack does not.
5. **Scrolling capture reliability** — App-specific scroll behavior and timing make this the highest schedule risk; keep it a spike with an explicit cut line.
6. **Cannot CI on our Linux box** — All verification is founder/manual or a future Mac CI runner; plan assumes no automated macOS build until hardware or cloud Mac exists.
7. **Overlay input theft** — Full-screen picker can fight Mission Control / Stage Manager / secure input fields; need robust Esc and click-through policy.
8. **Cursor compositing** — Hardware cursor is not always in the framebuffer; must draw cursor image explicitly when “cursor on.”

## 6. Engineering notes for whoever implements

- Prefer **ScreenCaptureKit** for content enumeration and still capture on supported OS.
- Keep **pure functions** for crop/border/shadow in Core for Linux-side review of logic tests (image golden tests can run later on Mac).
- No destinations/upload code paths even as stubs, so scope does not creep.
- Ship the working example (M0–M5) before annotation polish.

## Recommendation

Build an Xcode macOS app with a small Core library; hit **region + fullscreen/monitor + intent-before-capture + clipboard** first; time-box scrolling; treat founder checklist as the only gate until a Mac CI exists.
