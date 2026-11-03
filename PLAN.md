# ShareX for macOS: merged plan (awaiting founder approval)
Sources: plans/head-of-eng.md, plans/cto.md, plans/architect.md

## Stack
Swift 6, AppKit (overlay, hotkeys, clipboard), SwiftUI (settings, menu bar). ScreenCaptureKit only. macOS 14+. A menu-bar app, signed with Developer ID and notarized, not sandboxed in v1.

## Capture styles (chosen before the screenshot)
In: fullscreen, active monitor, monitor picker, active window, window picker, region, last region, freehand/lasso.
Pre-capture options: delay timer, show cursor, magnifier/crosshair, window border/shadow.
Phase 2: scrolling capture (needs Accessibility, fragile).
Out: video/GIF recording, OCR, webpage capture, uploads/destinations. This is a screenshot-only app.

## Annotation (core feature, as in ShareX region capture)
Annotate in the selection overlay before the shot is finalized, the way ShareX does it:
- Shapes: rectangle/box, ellipse, line, arrow.
- Highlight: translucent marker box.
- Area effects: blur, pixelate, spotlight (dims everything except one area).
- Drawing: freehand pen.
- Text: plain or with background.
- Numbered step markers.
- Crop.
Every tool has color, stroke width, fill and opacity settings, plus undo/redo and select/move/resize/delete. Tool hotkeys follow ShareX letters where possible. Enter or a double-click finalizes; Esc cancels.
Blur and pixelate are baked into pixels on export, not a removable layer, so the redaction can't be undone.

## Pipeline
Pick a style and options (CaptureRequest), then the delay runs. The screen freezes into a frozen frame and an overlay opens (one borderless window per screen, Retina-correct). In the overlay you select an area and annotate it. The annotations are flattened onto the crop, then border and shadow are added. The clipboard is cleared and gets one item holding both PNG and TIFF.

## Layout
CaptureCore (types, settings, LastRegionStore), CaptureKit (ScreenCaptureKit engine), CaptureUI (overlays, pickers), Annotate (shape model, tool renderers, undo stack, CoreImage blur/pixelate), App (menu bar, hotkeys via the KeyboardShortcuts package, no Accessibility needed).

## Milestones
M0 Screen Recording permission flow, plus fullscreen/active monitor to the clipboard
M1 region, last region, hotkeys
M2 annotation core: box, highlight, arrow/line, pen, blur/pixelate, text, undo/redo, tool settings bar
M3 the rest of annotation (ellipse, step markers, spotlight, crop, select/move/resize), window picker, lasso, delay, cursor, border/shadow
M4 polish: save to file, settings, magnifier, a "re-edit last capture" editor window
M5 time-boxed scrolling capture

## How we verify
Our box is Linux, so the founder builds in Xcode on a Mac and runs the checklist:
- the permission grant and denial paths
- multi-monitor and Retina crops
- Esc cancels
- every annotation tool shows up in the pasted image
- blur can't be reversed in the exported PNG
- pasting into Preview, Notes and Slack
- no upload UI anywhere

## Top risks
Annotation performance on 5K/multi-display frozen frames (render only the dirty region).
The Screen Recording (TCC) permission, coordinates on mixed-DPI multi-display setups, clipboard format mismatch, and the fragility of scrolling capture.
