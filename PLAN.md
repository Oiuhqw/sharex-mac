# ShareX for macOS: implementation and verification plan

This document replaces the original planning-only proposal. The older proposals in plans/ are historical.

## Implemented design

The app is a native menu-bar application for macOS 14 and later. AppKit owns capture windows and editing. SwiftUI owns Settings. ScreenCaptureKit supplies display and window images. CoreGraphics and CoreImage render the output. KeyboardShortcuts 3.1.0 supplies global shortcuts; no other external runtime package is used.

Packages/ShareXCore contains geometry, capture options, annotations, the editor document, undo history, and stored settings. App/Sources contains platform adapters and the UI.

The capture path checks permission, applies the selected delay, freezes pixels, and opens selection or editing. The editor retains the frozen frame and an ordered annotation document. Export flattens the selected area, adds the requested border or shadow, and encodes PNG and TIFF. Clipboard and local PNG writes have separate results. A failed destination can be retried without repeating a successful write.

## User controls

- Eight capture modes: region, freehand, window picker, active window, monitor picker, active monitor, fullscreen, and last region.
- Magnifier and crosshair during selection, plus a magnifier while adjusting a crop. Size labels show crop dimensions in image pixels, before border or shadow padding.
- Boxes, ellipses, lines, arrows, highlighter, blur, pixelation, spotlight, pen, text, numbered steps, and crop.
- Selection, movement, resizing, deletion, undo, and redo. Crop arrows move one image pixel; Shift moves ten pixels and Option adjusts the trailing edge.
- Capture, Shortcuts, and Output settings pages. Shortcut controls include search, native recording, conflicts, clear, per-command defaults, and restore-all confirmation.
- Clipboard output plus a local PNG for a new installation. Existing preferences are preserved.

## Privacy and resource rules

Earlier protected pixels remain protected when later blur or pixelation overlaps them. Later filter input replaces those protected pixels with opaque black. Unsafe or over-budget effect operations use an opaque fallback. Blur and pixelation remain visual obscuring tools; they are not a promise that the original content cannot be inferred.

Images are limited to 64 Mi pixels. Stored settings are limited to 1 MiB before parsing. Each owned shortcut string is limited to 1 KiB before decoding and must fit native integer widths. Recovery preserves valid assignments and leaves conflicting recovered defaults disabled. Committed effect patches are limited to 64 MiB and 128 entries. The cached live effect preview is limited to 16 MiB. Protection lookup is bounded by 1,024 candidates and 64 intersections per effect. These limits do not cap total process RSS.

Other recording apps can capture the editor, including pixels before the user finishes redacting them. The app does not claim that NSWindow.sharingType excludes modern recording APIs.

## Verification

The Windows host uses native tools without WSL. When enabled, the GitHub macOS workflow runs the core suite, AddressSanitizer, native app E2E, and Release performance/resource checks. E2E test code is excluded from the shipped app. An external process timeout preserves a native stack sample if the test driver stalls.

The performance gate requires Release hover p95 main-thread CPU below 2 ms and verifies event delivery. Debug timing, elapsed time, and display-link callbacks remain diagnostic measurements. They do not prove physical screen presentation time.

Memory checks record repeated sessions, buffer limits, object release, current RSS, peak RSS, and idle CPU. A separate diagnostic process traces image-provider lifetime and context caches. A successful ownership check alone is not proof of a low memory footprint.

The source security audit at `e8f9596` used explicit coverage and two independent coverage critics. All 47 source units were covered and no qualifying vulnerability was found. Audit-driven reliability changes received separate source review. At `a5cb376`, both Intel and Apple silicon passed 97 core tests, 97 AddressSanitizer tests, and 483 native E2E checks, with six hardware-dependent checks explicitly unavailable. See [the review index](reviews/README.md) for current evidence and historical reports.

## Delivery status

[PR 3](https://github.com/Oiuhqw/sharex-mac/pull/3) merged as `65a3e36`. The [main run](https://github.com/Oiuhqw/sharex-mac/actions/runs/42038241966) passed native validation and built the universal 0.1.2 DMG. The reviewed PR head and merge commit have identical file trees. Documentation-only changes after this build do not change application or installer inputs.

On 5 November 2026, cleanup removed the retired worktrees and feature branches after verified local backups. It retained the cited validation runs and disabled both GitHub Actions workflows at the owner's request. A new hosted build requires enabling the workflows first. See [README.md](README.md#latest-built-package) for the existing package and build instructions.

## Release limits and deferred features

The current package is ad-hoc signed with Hardened Runtime. It is not Apple-notarized. Developer ID signing and notarization need the owner's Apple credentials. Physical keyboard, permission-prompt, Retina, and mixed-monitor checks remain separate hardware checks.

Scrolling capture, video, GIF recording, OCR, uploads, and re-editing a prior capture are not implemented in this version.
