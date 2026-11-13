# Capture and edit a screenshot

ShareX requires macOS 14 or later on Apple Silicon. Intel Macs are unsupported. Download the [0.1.6 release](https://github.com/Oiuhqw/sharex-mac/releases/tag/v0.1.6), then follow the [installation instructions](../INSTALL.txt). The package is ad-hoc signed with Hardened Runtime and is not notarized.

ShareX runs in the menu bar. Open the camera icon to start a capture or open **Settings…**.

The development source also includes agent screenshots and video recording. See the [agent capture guide](AGENT-CAPTURE.md) for setup and use with Claude Code, Codex, or scripts. This feature is not in the published 0.1.6 package.

## Make your first capture

1. Open ShareX from Applications.
2. Allow Screen Recording in **System Settings > Privacy & Security** when macOS requests it.
3. Quit and reopen ShareX after you change that permission.
4. Open the camera icon in the menu bar and choose **Region**.
5. To add marks or redactions, click an annotation icon in the top toolbar and draw on the screen.
6. Choose **Region** or press **Tab** to select the final capture area.
7. Drag around the area you want. Release the mouse to copy the finished image automatically.
8. Open the destination app and choose **Edit > Paste**.

For a plain screenshot, drag the region immediately. Region and Freehand need no **Done** click. Drawing and tool changes do not copy or save intermediate images.

A new installation also saves a PNG in `~/Pictures/ShareX`. An update preserves your existing save preference and folder. **Control-Shift-1** is the only global shortcut assigned on a new installation.

Press **Esc** once or click **Cancel** to close the capture and return to the live desktop without copying or saving. This also works while you type text, drag a selection, or use the Style popover. Other toolbar commands commit active text before they run. **Tab** commits text and returns to Region selection. **Return** commits active text; with no text field active, it finishes a fixed-area editor.

## Choose a capture

Choose a command from the ShareX menu. Each command can also have a custom shortcut in Settings.

| Command | What to capture | New-install shortcut |
| --- | --- | --- |
| Region | Drag a rectangle across one or more displays. | Control-Shift-1 |
| Window… | Click a window. | Unassigned |
| Fullscreen | Capture all connected displays in one image. | Unassigned |
| Active Monitor | Capture the display under the pointer. | Unassigned |
| Freehand | Draw around an area across one or more displays. The area outside the path is transparent. | Unassigned |
| Active Window | Capture the frontmost window. | Unassigned |
| Monitor… | Click a display. | Unassigned |
| Last Region | Capture the previous area again. | Unassigned |

The fixed top toolbar appears on every display. Capture modes and annotation tools have separate icon buttons. Hover over a button to see its name and shortcut. The selected tool is highlighted and named below the icons. On narrow displays, the buttons wrap into rows. Choose **Region** or **Freehand** after drawing, then release the final selection to copy. **Full Desktop** copies the entire frozen desktop with its annotations. **Window** becomes unavailable when annotations exist because a fresh window image would discard them. Fullscreen editing stays on the original displays. An annotation drag can cross a display boundary and remains one undo action.

The editor uses a frozen image. Window takes a fresh still image when you click the window. Active Window also takes a fresh still image. When editing is enabled, these captures open a titled canvas.

If a participating display moves, changes size, or disconnects, **Last Region** starts a new Region selection. Common desktop translation, scale changes, and extra untouched displays preserve the saved area. Empty desktop gaps remain transparent in the exported image.

In **Settings… > Capture**, set a delay to capture a menu or another temporary view. You can also include the pointer, add a border or shadow, and enable **Open the editor for fixed-area captures**.

## Select an exact area

Enable **Settings… > Capture > Show magnifier**. The small crosshair has a white centre stroke and a black outline so it stays visible on light and dark areas. The circular magnifier shows enlarged pixels and marks the pixel under the pointer. Use it during Region or Freehand selection. The size label shows crop dimensions in image pixels, before any border or shadow.

Region and Freehand finish when you release the selection. To adjust a crop before export, use a fixed-area capture with **Open the editor for fixed-area captures** enabled, then choose **Crop**. Drag a crop handle to resize the area, or drag elsewhere to replace it. The magnifier also works in Crop. It hides near protected areas to avoid showing the original pixels beneath a redaction.

These optional keys make small adjustments:

| Keys | Adjustment |
| --- | --- |
| Arrow key | Move the crop by one image pixel. |
| Shift+Arrow | Move the crop by ten image pixels. |
| Option+Left or Option+Right | Move the right edge by one image pixel. |
| Option+Up or Option+Down | Move the bottom edge by one image pixel. |
| Option+Shift+Arrow | Adjust the same edge by ten image pixels. |

## Add or change annotations

Click a tool icon in the top toolbar. Drag to draw shapes and strokes. Click to place text or a step marker. The keys below are optional.

| Tool | Optional key | Use |
| --- | --- | --- |
| Select | V | Select and move an annotation. Drag its handles to resize it. |
| Rectangle | R | Draw a box. Enable **Fill** for a solid box. |
| Ellipse | E | Draw an oval. |
| Line | L | Draw a line. |
| Arrow | A | Point to an item. |
| Highlighter | H | Tint an area. |
| Blur | B | Blur an area. |
| Pixelate | P | Replace detail with blocks. |
| Smart Eraser | M | Remove small objects on plain or smooth backgrounds. |
| Spotlight | S | Dim the area outside a shape. |
| Pen | F | Draw a pen stroke. |
| Text | T | Add text. To edit existing text, select this tool and click the text. |
| Step marker | I | Add a numbered marker. |

Open **Style** to change color, width or text size, opacity, fill, and effect strength. The selected color, numeric values, and preview show the current style before you draw. Slider changes update the selected annotation while you drag. One undo restores the style from before that drag. Controls apply only to tools that use them. Choose **Reset tool style** to restore the current tool's default style. Hold **Shift** while drawing a shape if you want to constrain it.

To move an annotation, choose **Select**, then drag the annotation. Optional arrow keys move it by one point. **Shift+Arrow** moves it by ten points.

Choose **Delete selected** to remove the selected annotation. A right-click also deletes the annotation under the pointer. With no annotations, a right-click returns to area selection or cancels a fixed-area capture.

Choose **Undo** or **Redo** to change the shared history. Returning to Region selection preserves your annotations and history. Release the final region to finish, or click **Cancel** to close without export. Fixed-area editors retain **Done**, Return, and Command+C. Command+Z and Shift+Command+Z work before and after a crop exists.

## Remove a small object

Choose **Smart Eraser** or press **M**. Drag a rectangle around the complete object, with a small margin of background. The tool estimates the background from nearby pixels. It runs locally and works best on plain areas and smooth gradients, such as a screenshot with text on a panel.

Choose **Select** to move or resize the repair. **Undo** removes the repair, and **Redo** restores it. The exported image uses the same repair as the editor. Complex textures and photographs can produce visible seams. Use a smaller area or undo an unsuitable result.

The tool excludes protected content from its background samples. If it cannot produce a safe repair, it covers the area instead. Use the opaque rectangle procedure below for sensitive content.

## Hide sensitive content

Blur and pixelation obscure detail but do not guarantee that the content cannot be inferred. To cover sensitive content completely:

1. Choose **Rectangle**.
2. Open **Style** and select a color, such as black.
3. Enable **Fill**.
4. Move **Opacity** fully right to make the box opaque.
5. Draw the box over the entire sensitive area.
6. Check the finished image before sharing it.

Other screen-recording or screen-sharing apps may capture the editor before you finish the redactions. Stop those apps before opening sensitive content.

## Start automatically at login

Launch ShareX once from Applications. On the first normal launch after this update, ShareX registers to start each time you sign in. Capture shortcuts are then available from the menu bar.

Use **Settings… > Capture > Startup > Launch ShareX at login** to change this setting. The status text shows the current macOS registration. If approval is needed, click **Open Login Items…** and allow ShareX. Turning startup off here or in System Settings remains effective when you reopen ShareX.

## Set shortcuts

Open **Settings… > Shortcuts**. Changes save automatically.

![Shortcut settings with search and editable capture shortcuts](assets/settings-shortcuts.png)

1. Use **Search shortcuts** to find a command.
2. Click its shortcut control.
3. Press your key combination, then release it. Press **Esc** to cancel.

If another ShareX command uses the combination, the app rejects it and names the conflict. Clear or change the other assignment, or choose another combination.

Use the row's options menu to select **Clear Shortcut** or **Restore Default**. A per-command restore also checks for a conflict. Use **Restore All Defaults…** and confirm **Restore Defaults** to replace all eight assignments. Region receives Control-Shift-1. The other seven commands become unassigned.

Existing valid bindings, including earlier factory defaults, remain assigned until you change or restore them. The screenshot can therefore show more assigned shortcuts than a new installation.

If a stored shortcut is damaged, the app recovers it at launch. Valid custom and disabled assignments stay unchanged. A recovered default that conflicts with a valid assignment stays unassigned.

## Save and recover an image

Open **Settings… > Output**. Leave **Save each capture to a folder** enabled to save a PNG as well as the clipboard image. Use **Choose Folder…** to select the destination. **Use Default Folder** restores `~/Pictures/ShareX`. Check the folder status below these controls.

Saving is enabled on a new installation and when old settings have no save preference. An explicit choice to turn saving off stays off after an update. The capture toolbar shows the current output destination before you finish.

Turn off **Save each capture to a folder** for clipboard-only output. The clipboard image supports both PNG and TIFF.

If an output fails, read the alert to see which destination succeeded. **Retry** repeats only the failed output. **Save As…** lets you save the PNG elsewhere. Check folder permissions and available disk space if the file cannot be saved.

Keep the recovery dialog open until you have the output you need. **Done** dismisses the dialog when at least one output succeeded. **Discard** dismisses it when neither succeeded. The success sound plays only after every requested output succeeds.

Use **Preview capture sound** in Output settings to hear the short shutter click. Turn off **Play a sound after capture** for silent captures.

## Reduce a large capture

If a selected area exceeds the output limit, the editor stays open with a size message. Choose **Crop**, reduce the area, and click **Done**. The limit is 64 Mi pixels. The image uses the highest scale of the displays that the crop touches. The app does not reduce image detail to fit the limit.

If the display layout changes while you edit, the session cancels. Start a new capture after the displays settle.

## Understand the validation limits

The [0.1.3 assessment](../reviews/multidisplay-0.1.3.md) records automated native checks on real virtual-display geometry at 1x and 2x. Those checks use deterministic frozen tiles and actual ScreenCaptureKit editor-window images.

Physical mouse transitions, separate Spaces, physical display hot-plug, real mixed-density display capture, physical shortcuts, and interactive permission prompts remain checks for physical Macs.
