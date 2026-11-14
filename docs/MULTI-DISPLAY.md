# Multi-display capture and validation

Version 0.2.1, build 9 supports macOS 14 or later on Apple Silicon. Intel Macs are unsupported. The project and release package target arm64 only. The [release](https://github.com/Oiuhqw/sharex-mac/releases/tag/v0.2.1) provides the DMG and its checksum.

## Shared editing state

`EditorSession` owns the document, history, gesture, native text field, renderer, and terminal outcome. Each original display has a borderless panel. A held drag converts events through its originating window into frozen desktop coordinates. Other panels remain interactive after selection. The titled window-capture canvas uses the same session model.

`DesktopImageSource` holds native display tiles and their point placements. It does not allocate the desktop union. The crop chooses the maximum scale of displays with a positive-area intersection. Scale changes clear effect patches, live patches, and protection geometry before all viewports redraw. Annotation history stays in points.

Effects sample the annotation rectangle, including both tiles at a seam. The source receives an opaque matte and prior protection masks before clamping. Pixelation retains `EffectMath.pixelateCenter`. The existing 16 Mi-pixel effect-source limit, 64 MiB effect cache, 16 MiB live-patch limit, and 64 Mi-pixel output limit remain in force. Gaps stay transparent in frame export. Failed redactions remain opaque.

The toolbar stays at the safe top of each panel. Direct tool icons and separate Undo, Redo, and Delete selected buttons provide editing controls. Style opens a popover with live values and a preview. Done and Cancel remain visible at narrow widths. Toolbar background clicks do not create annotations. The single text field commits before a command or host change. Closing a panel, cancelling, or changing display topology ends the session once.

## Native test inputs

The [current verification report](../.audit/capture-polish-verification.md) records the latest source identity, exact results, and diagnostic artifacts. The [0.1.3 assessment](../reviews/multidisplay-0.1.3.md) retains the original multi-display validation. The dedicated driver runs two layouts with real `NSScreen` displays:

| Layout | Display modes | Coverage |
| --- | --- | --- |
| `horizontal` | Two 1280 by 800 logical displays, one at 1x and one at 2x. | Horizontal seam, both gesture directions, and negative desktop coordinates. |
| `vertical-negative` | The same 1x and 2x modes. | Vertical seam, both gesture directions, and negative desktop coordinates. |

The helper writes actual Core Graphics and Cocoa geometry to `ready.json` and the logs. Test tiles are deterministic frozen fixtures on that geometry. They do not establish that ScreenCaptureKit captured textured physical display pixels.

ScreenCaptureKit separately captures actual editor windows. Native image comparisons check seam projection, effects, and visible content. Software layer comparisons and delivered PNG checks remain separate required assertions. The native comparison excludes only the actual toolbar and visible crop-size label rectangles. Each panel requires at least 16 samples, including four near the seam. RGB-sum tolerance remains 0.04, and alpha tolerance remains 0.01.

The display suites cover shared undo, rectangular selection across the seam in both directions, text host changes, toolbar and Style containment, fullscreen panels, sparse crops, and scale-change cache invalidation. Clipboard and PNG checks inspect delivered dimensions and pixels.

The baseline and Release regression fixture checks rectangular and freehand gestures across two native windows on one display. It uses a synthetic two-tile layout with a nonzero viewport origin. It checks selection coordinates, native window pixels, output pixels, compact controls, and posted mouse Done or Cancel. This fixture does not prove freehand selection across physical mixed-scale displays.

Last Region checks mutate participating display geometry during a countdown and after capture freezes. The logs record immutable anchor geometry, requested and actual layouts, and timing. The checks require either the correct participant-only output or fresh selection when the saved geometry is no longer valid.

## Run the native checks

On the Apple Silicon GitHub runner, build the Debug app with `SHAREX_E2E`. Run the baseline suite first to establish its existing permission grants. Then run:

```sh
scripts/e2e-multidisplay.sh
```

The script builds the external display helper, runs both layouts, and keeps evidence under `e2e-out/multidisplay`. Each layout has a separate directory with `ready.json`, `helper.log`, `e2e.log`, `results.json`, and images.

To run the dedicated app driver with at least two available `NSScreen` displays:

```sh
ShareX.app/Contents/MacOS/ShareX --e2e-multidisplay /tmp/sharex-multidisplay --multidisplay-layout horizontal
```

Use a separate output directory for `vertical-negative`. The driver prefers helper displays with vendor 505 and model `0x5358`.

The helper's teardown check requires zero live display objects and a successful complete online-display enumeration with both created IDs absent. An API error or failure to reach that state within three seconds fails cleanup. Scalar queries against removed IDs are diagnostic only.

Run the normal app E2E, shortcut recovery, core XCTest, core AddressSanitizer, Release, and memory checks as well. The package must exclude all `SHAREX_E2E` code. Private virtual-display APIs belong only to the external test helper. Package inspection rejects the helper and private API references in the app.

## Settings compatibility

Last Region retains the original `displayID` and `rect` keys. New values add participant frames relative to an anchor display. Common translation and backing-scale changes are allowed. A missing, moved, or resized participant starts fresh Region selection. Extra untouched displays do not invalidate the saved area. Delivery saves Last Region only after an output succeeds.

KeyboardShortcuts 3.1.0 writes initial bindings into UserDefaults only when a key is absent. Removing an initial binding from a command declaration leaves an existing value untouched. The app preserves explicit old defaults, custom bindings, and disabled values. Restore All uses eight stable command names and assigns only Control-Shift-1 to Region.

## Coverage limits

Native virtual-display geometry, app events, and window captures do not prove physical mouse routing across monitors. Separate Spaces, physical display hot-plug, real mixed-density display capture, interactive permission prompts, and physical shortcut use remain unverified hardware scenarios.

The baseline suite and each dedicated display layout report their unavailable cases separately. An unverified case is not a passing check. The diagnostic package does not identify the final release package because the final documentation changes include `INSTALL.txt`. The final PR and release provide the reviewed source, merged-main package build, and checksum in the release notes.
