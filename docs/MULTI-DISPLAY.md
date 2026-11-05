# Multi-display capture and validation

The app supports Apple Silicon Macs running macOS 14 or later. Intel Macs are unsupported. Xcode project settings and release packaging target arm64 only.

`EditorSession` owns the document, history, gesture, native text field, renderer, and terminal outcome. Each original display has a borderless panel. A held drag converts events through its originating window into frozen desktop coordinates. The other panels remain interactive after selection. Canvas editing uses the same session.

`DesktopImageSource` holds the captured native tiles and their point placements. It does not allocate the desktop union. The crop chooses the maximum scale of the displays with a positive-area intersection. Scale changes clear effect patches, live patches, and protection geometry before every viewport redraws. Annotation history stays in points.

Effects sample the annotation rectangle, including both tiles at a seam. The source receives an opaque matte and prior protection masks before clamping. Pixelation retains `EffectMath.pixelateCenter`. The existing 16 Mi-pixel effect-source bound, 64 MiB effect cache, 16 MiB live-patch limit, and 64 Mi-pixel output limit remain in force. Gaps stay transparent in frame export. Failed redactions remain opaque.

The toolbar stays at the safe top of each panel. Tool and More are labeled menus. Style opens a popover. Done and Cancel stay visible at narrow widths. Toolbar background clicks do not create annotations. The single text field commits before a command or host change. Closing one panel, Escape, or a display topology change ends the session once.

## Run native display checks

Build with `SHAREX_E2E`. Supply at least two NSScreen displays. The dedicated driver prefers virtual displays with vendor 505 and model `0x5358`.

```sh
ShareX.app/Contents/MacOS/ShareX --e2e-multidisplay /tmp/sharex-multidisplay --multidisplay-layout horizontal
```

Use a separate output directory for `vertical-negative`. The driver writes `results.json` and panel images. It checks both native drag routes, shared undo, seam preview and export pixels, redaction failure coverage, text host changes, fixed toolbar placement, mouse completion, fullscreen panel presence, sparse desktop crops, and cache invalidation after scale changes. Its tile patterns are deterministic fixtures on real NSScreen geometry. This is not a claim that those pixels came from ScreenCaptureKit.

On the Apple Silicon GitHub macos-15 runner, `scripts/e2e-multidisplay.sh` builds the external display helper and runs both layouts after the baseline E2E suite. The helper supplies one 1x and one 2x display, each 1280 by 800 logical points. It writes each layout to `ready.json`. The script stops the helper after each run and keeps logs under `e2e-out/multidisplay`. Private virtual-display interfaces remain in this test helper and are not part of the app.

Run the normal app E2E, shortcut recovery E2E, core XCTest suite, and core AddressSanitizer suite as well. E2E sources stay behind `SHAREX_E2E` and must remain absent from the release package.

Windows static checks do not prove AppKit behavior. Native compilation, E2E, physical mouse routing across monitors, real mixed-density hardware, and separate Spaces remain validation requirements. The driver records physical routing and separate Spaces as unverified.

## Settings compatibility

Last Region retains the original `displayID` and `rect` keys. New values add participant frames relative to an anchor display. Common translation and backing-scale changes are allowed. A missing, moved, or resized participant starts fresh Region selection. Extra untouched displays do not invalidate the saved region. Delivery still saves Last Region only after an output succeeds.

KeyboardShortcuts 3.1.0 writes initial bindings into UserDefaults only when the key is absent. Removing an initial binding from the command declaration leaves an existing value untouched. The app therefore preserves explicit old defaults, custom bindings, and disabled values. Restore All uses the eight stable command names and reports one assigned factory shortcut.

The source version is 0.1.3, build 4. This document does not claim a new packaged or notarized release.
