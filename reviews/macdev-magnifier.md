# Mac dev review: selection magnifier (loupe) on macOS 27 / M5 Pro / 120 Hz

Reviewed: `origin/codex/fix-export-release` @ 9cabccb, in a detached worktree at `/tmp/wtmag`. I did not edit, commit or switch branches in the main clone. That clone is on `fix/magnifier`, where another agent is working.
Evidence also includes CI run 41798268706 on `fix/magnifier` (e8a80a3, "E2E: loupe probe"), with artifacts `e2e/loupe*.png` and `e2e.log`.

## What the code does

| Check | Finding |
|---|---|
| Setting | `CaptureOptions.showMagnifier = true` by default (Capture.swift:56). The decoder keeps the default when the key is missing (:73). It is global, not per style. It is read at OverlayController.swift:69 and is toggleable in the menu (App.swift:98) and in Settings (SettingsView.swift:31). |
| Gate | EditorView.swift:427 shows the loupe only when `showMagnifier`, mode is `.rectangle` or `.lasso`, and `mouse != nil`. There is no loupe in pickWindow or pickMonitor (ShareX shows one in region mode, which includes window hover). |
| Create / add / update | ChromeView.init (EditorLayers.swift:206–235) creates the `magnifier`, `magMid` and `magLabel` layers, all hidden, with actions nulled. `apply` (:296) calls `layoutMagnifier` (:302–326), which sets the frame, `contents = crop` and `contentsRect`, then unhides the layer. |
| Layer order | `frameView` is added first and `chrome` second (EditorView.swift:85–86). The opaque AnnotationsView is inserted `.above frameView`, so it sits below chrome (:434), and it is hidden while selecting (:420). The magnifier comes after `dim` in the sublayer order, so it draws on top. There is no zPosition, but none is needed today. |
| Hidden / opacity / frame | The layer is unhidden every time `s.magnifier != nil`. Its frame is 120×120 at cursor+20, flipped at the right and bottom edges only. It is not clamped at the left or top, so when the flipped origin is below 0 the loupe goes off-screen. |
| Sampling | `source()` (:328) gives `floor(p*s) - 7`, 15×15, in Y-down CGImage space. That matches `cropping(to:)`, so no Y flip is needed. `.nearest`, `contentsGravity = .resize`, and `contentsRect` handle the partial crop at the edges. |
| Mouse events | Window: `acceptsMouseMovedEvents = true` (OverlayController.swift:134), made key and first responder in `show()` (:145–151). View: `NSTrackingArea [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited]` is added only in `updateTrackingAreas()` (EditorView.swift:97–101). Nothing adds it in init or `viewDidMoveToWindow`. `mouseMoved` (:167) sets `mouse`, then `refresh()`. `mouse` stays nil until the first move or drag event; it is never seeded from `mouseLocationOutsideOfEventStream`. |
| Perf pass | Nothing in the perf commits changed this path. Drag rendering is about 5.5 ms per event in CI. |
| E2E | It never covered the on-screen loupe before e8a80a3. Earlier PNGs are exports, and the overlay is `sharingType = .none`. |

## The key evidence: CI loupe probe (e8a80a3)

| Step | cellsMatching | eventMs | Screenshot |
|---|---|---|---|
| hover (mouseMoved 60,50) | 0.004 | 0.02 | No loupe and **no dim at all**: chrome did not update |
| moved (mouseMoved 101.5,80) | 0.004 | 0.02 | Same |
| dragEdge (leftMouseDragged 250,200) | **1.00** | 5.48 | Correct loupe: upright, 8×, flipped left/up at the edge, red centre cell, `X: 500 Y: 400` |

When the loupe does appear, the drawing is correct. Layers, z-order, crop maths, orientation, `.nearest` and `contentsRect` all work for a non-clipped crop. The defect is on the **hover path**: the move events never reach `EditorView.mouseMoved`. A 0.02 ms event means no refresh ran.

The probe is not a perfect copy of the real app. It does not set `acceptsMouseMovedEvents`, it never makes the window key or the view first responder, and a synthetic `sendEvent(.mouseMoved)` skips window-server tracking-area dispatch. So it proves the renderer is fine, but it does not by itself prove why hover fails on the user's Mac.

## Ranked root-cause hypotheses

1. **(Most likely) Move events do not reach the view on a real Mac.** Rendering works and runs only from `mouseMoved` while hovering, so this is the top suspect. There are two ways it can happen:
   - a. **The tracking area is never installed** (EditorView.swift:97–101). It relies on AppKit calling `updateTrackingAreas` for a view placed as `contentView` of a borderless window built before it is ordered front. If that call does not happen, or happens before the window exists, there is no `.activeAlways` area.
   - b. **The overlay is not the key window of the active app.** `NSApp.activate()` (OverlayController.swift:145) uses cooperative activation on macOS 14 and later. When it is triggered from a global hotkey while another app is frontmost, the system may decline it. Then the `acceptsMouseMovedEvents` path (it only delivers to the key window of the active app) gives nothing. Clicks and drags still work because of `acceptsFirstMouse` (:94), so "everything else works", and **the loupe would appear only while dragging**.

   **Confirm on the Mac:**
   - Log in `mouseMoved` and `updateTrackingAreas`, plus `trackingAreas.count`, `window.isKeyWindow` and `NSApp.isActive` in `show()` after activation.
   - Ask the user whether the loupe appears while dragging a region. If yes, this hypothesis is confirmed.
   - Ask whether hovering a window highlights it in Region mode (that also comes from `mouseMoved`). If it does not, also confirmed.
2. **Multi-display: the non-key overlay never gets moves.** Only one surface is made key (OverlayController.swift:148–150). A secondary screen only gets moves from the tracking area, so it is the same root as 1a. **Confirm:** hover on the second screen, and log which `EditorView` instance receives `mouseMoved`.
3. **The loupe is off-screen or wrongly placed at the screen edges.**
   - Placement: it flips only at the right and bottom edges, with no clamp at the left or top (EditorLayers.swift:304–306). On the 120 pt-tall menu-bar strip or near the top-left corner, the flipped origin can be negative.
   - Clipped crop: the edge `contentsRect` maths (:311–316) has never been tested near y = 0. In a flipped layer, the Y of `contentsRect` is a risk.
   - This would make the loupe disappear in some places, not everywhere. **Confirm:** run the probe with the cursor at (3,3) and at (w-3,h-3).
4. **The setting is off for this user.** It defaults to true and the decoder keeps the default, but the menu toggle (App.swift:98/133) is one click away. **Confirm:** read `showMagnifier` in the user's settings JSON, or check the menu checkmark.
5. **The mode gate.** Only `.rectangle` and `.lasso` get a loupe (EditorView.swift:427). If the user captures with Window or Monitor styles, they get no loupe by design. **Confirm:** ask which hotkey or style the user used.
6. **The crop is nil or not drawable.** `cropping(to:)` on an SCK frame that is IOSurface-backed or extended-range (XDR panel) could return nil or fail to draw as `contents`. This is unlikely, because FrameView shows the same image through `layer.contents`, and a nil crop would still show a black box with a border and label. **Confirm:** log `crop == nil` and `crop.bitsPerComponent` / colour space.
7. **120 Hz / ProMotion.** Unlikely. Coalesced moves still call `mouseMoved`.

## Design I'd sign

- **Size and sampling:** 15×15 source pixels at 8×, so 120 pt. The centre cell is the pixel under the cursor, `floor(p*scale)` in frame pixels.
- **Nearest neighbour without per-move allocation:** set `contents = frame` once per session, use `.nearest`, and choose the pixels by changing `contentsRect` only. There is no `cropping(to:)` per event, and no clipping maths, because out-of-image cells come from a black background sublayer that shows through. The `contentsRect` Y must match the layer's flip; the probe must test this at the corners.
- **Overlays:** a red 1-pt outline on the centre cell, a faint grid (optional), and the full-screen crosshair (ShareX style). Readout: `X: px  Y: px` in frame pixels, matching the export.
- **Placement:** default offset +20,+20; flip on any axis that would overflow, then **clamp to the screen bounds** on all four sides, with room for the label.
- **Own layer:** a container at `zPosition = 1000` above all chrome, with actions disabled through a delegate or a nulled `actions` dict. All updates go in one `setDisableActions(true)` transaction.
- **Hot path:** each move changes only `position` and `contentsRect`, plus the label string and crosshair path. Target: about 1 ms or less per move.
- **Events:**
  - Install the tracking area in `viewDidMoveToWindow` as well as `updateTrackingAreas`, with `[.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited]`.
  - Seed `mouse` from `window.mouseLocationOutsideOfEventStream` when the overlay is shown, so the loupe is there before the first move.
  - Keep `acceptsMouseMovedEvents` and `makeKeyAndOrderFront`. Do not depend on activation.
- **One loupe per overlay:** each EditorView owns its own loupe. `mouseExited` and `deactivate()` hide it, so only the screen under the cursor shows one.
- **While dragging:** ShareX hides the magnifier while a region is being dragged. Today's code keeps it during the drag, so this is a product choice; I would follow ShareX and hide it in `.region` drag, keeping the crosshair. Note that this would make hover the *only* time the loupe shows, which makes the event fix mandatory.
- **Modes:** show it in rectangle, lasso and window-hover (rectangle with picks). It can stay off in pickMonitor.
- **Test (blocking):** the probe has to use the real delivery path:
  - set `acceptsMouseMovedEvents`;
  - make the window key and the view first responder;
  - post the move with `CGEvent(mouseEventSource:mouseType:.mouseMoved,…).post(tap: .cghidEventTap)`, or call the view's `mouseMoved` directly and assert on `trackingAreas.count > 0` separately;
  - check hover, move, a corner (0,0), a far corner, and that the loupe is hidden while dragging;
  - require `cellsMatching > 0.9` and `eventMs < 2`.

```swift
final class Loupe {
    static let n: CGFloat = 15, zoom: CGFloat = 8, side = n * zoom
    let root = CALayer(), pixels = CALayer(), mid = CALayer(), label = CATextLayer()
    private let frameSize: CGSize            // pixels
    init(frame: CGImage, contentsScale s: CGFloat) {
        frameSize = CGSize(width: frame.width, height: frame.height)
        root.zPosition = 1000; root.isHidden = true
        root.backgroundColor = CGColor(gray: 0, alpha: 1)          // out-of-image cells read black
        root.borderColor = .white; root.borderWidth = 2; root.masksToBounds = true
        root.bounds.size = CGSize(width: Self.side, height: Self.side)
        pixels.contents = frame                                     // set once per session
        pixels.magnificationFilter = .nearest; pixels.contentsGravity = .resize
        pixels.frame = root.bounds
        mid.borderColor = CGColor(srgbRed: 1, green: 0.2, blue: 0.2, alpha: 1); mid.borderWidth = 1
        mid.frame = CGRect(x: 7 * Self.zoom, y: 7 * Self.zoom, width: Self.zoom, height: Self.zoom)
        label.contentsScale = s; label.fontSize = 11
        root.addSublayer(pixels); root.addSublayer(mid)
        for l in [root, pixels, mid, label] { l.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
                                                         "contentsRect": NSNull(), "hidden": NSNull(), "string": NSNull()] }
    }
    /// p: view points (flipped, y-down). bounds: this screen's overlay bounds. s: frame px per pt.
    func update(_ p: CGPoint, in bounds: CGRect, scale s: CGFloat) {
        let cx = (p.x * s).rounded(.down), cy = (p.y * s).rounded(.down)
        // Unit-space window onto the frame; cells beyond the image fall outside [0,1] and show root's black.
        pixels.contentsRect = CGRect(x: (cx - 7) / frameSize.width, y: (cy - 7) / frameSize.height,
                                     width: Self.n / frameSize.width, height: Self.n / frameSize.height)
        // NB: verify Y in the flipped tree at the corners; if inverted use y: 1 - (cy + 8) / h.
        let lh: CGFloat = 18, side = Self.side
        var o = CGPoint(x: p.x + 20, y: p.y + 20)
        if o.x + side > bounds.maxX { o.x = p.x - 20 - side }
        if o.y + side + lh > bounds.maxY { o.y = p.y - 20 - side - lh }
        o.x = min(max(o.x, bounds.minX), bounds.maxX - side)
        o.y = min(max(o.y, bounds.minY), bounds.maxY - side - lh)
        root.frame.origin = o
        label.string = " X: \(Int(cx))  Y: \(Int(cy)) "
        label.frame = CGRect(x: o.x, y: o.y + side + 2, width: 120, height: 16)
        root.isHidden = false; label.isHidden = false
    }
    func hide() { root.isHidden = true; label.isHidden = true }
}

// EditorView
override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow(); updateTrackingAreas()
    if let w = window { mouse = convert(w.mouseLocationOutsideOfEventStream, from: nil); refresh() }  // loupe before first move
}
override func updateTrackingAreas() {
    super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited,
                                                          .enabledDuringMouseDrag], owner: self))
}
// refresh(), selecting phase:
//   let dragging = { if case .region = drag, dragMoved { return true }; return false }()
//   if showMagnifier, mode != .pickMonitor, let m = mouse, bounds0.contains(m), !dragging {
//       CATransaction.begin(); CATransaction.setDisableActions(true)
//       loupe.update(m, in: bounds0, scale: renderer.scale); c.crosshair = m
//       CATransaction.commit()
//   } else { loupe.hide() }
// mouseExited / deactivate(): loupe.hide()
```

## Verdict
I would **BLOCK** any fix that changes only rendering. The CI probe shows rendering is correct (drag result 1.00). The fix I'd sign:
1. installs the tracking area for certain, seeds the initial mouse position, and does not depend on the app being active;
2. moves to the `contentsRect`-only loupe described above, clamped per screen and hidden while dragging;
3. ships an E2E probe that delivers a hover through the real event path, and checks corners and the hidden-while-dragging case.

Ask the user one question to settle hypothesis 1b: "Does the loupe show while you drag?"
