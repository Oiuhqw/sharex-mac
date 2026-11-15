# Record video and maintain ShareX

These controls are in the development source. They are not included in the downloadable 0.2.1 package.

## Record a display or window

1. Open the ShareX menu and choose **Record Screen…**.
2. Select a display or window. If a target is missing, click **Refresh**.
3. Choose whether to include the cursor.
4. Click **Start Recording**.
5. Click **Stop Recording** in the window or menu.
6. Wait for **Recording saved**, then click **Reveal MP4**.

You can close and reopen the recording window while capture runs. The window shows elapsed time and any error. Capture is silent H.264 MP4 at 30 fps. The default limits are 30 minutes, 2 GiB, and 3840 by 2160 pixels. ShareX keeps 256 MiB of disk reserve.

Manual recording works while local agent access is off. Only one recording can run at a time. An agent cannot stop a manual recording, add markers to it, or attach screenshots to it. This ownership remains in the saved manifest after restart. A person can stop either kind of recording from ShareX.

Recordings and manifests remain in `~/Library/Application Support/ShareX/AgentSessions`. If capture fails, ShareX preserves the available evidence and shows its folder. An incomplete file is not a verified movie.

## Repair permission after an update

1. Close any screenshot editor or finish the screenshot export.
2. Open **Settings > Maintenance**.
3. Click **Reset Screen Recording Permission & Quit**.
4. Review the action, then confirm it.
5. Reopen ShareX and grant Screen Recording permission when macOS requests it.

ShareX finishes any active recording before it resets permission. If finalization fails, maintenance stops and reports the error. **Retry** opens a new review that explains the preserved incomplete evidence. Confirming that new review permits the remaining maintenance steps.

The reset runs `/usr/bin/tccutil reset ScreenCapture com.sharexmac.ShareX` for the current account. It keeps the app, CLI, preferences, launch-at-login setting, and capture files. macOS may require another restart after the new grant. The reset does not give future ad-hoc builds a stable signing identity.

## Uninstall this copy

1. Close other running ShareX copies.
2. Finish or cancel any screenshot editor or export.
3. Open **Settings > Maintenance** and click **Uninstall ShareX…**.
4. Read the exact app path and CLI disposition.
5. Confirm the uninstall, or click **Cancel** to leave the app unchanged.

ShareX saves any active recording first. It then unregisters launch at login, removes its exact CLI wrapper, clears its preference domain, resets its permissions, and moves the reviewed app to Trash. It quits after those steps succeed.

The CLI is removed only when its full contents match the wrapper for this running executable. Foreign commands, symbolic links, hard links, and wrappers for other installations are preserved. Unsafe parent directories stop the operation. A changed app or owned wrapper requires a new review before cleanup continues.

ShareX preserves screenshots, all session folders, parent directories, and agent client configuration files. Permissions and preferences use `com.sharexmac.ShareX` across installed copies. The uninstall resets all permissions for that bundle ID in the current macOS account.

To remove a client registration you created, run the matching command in your terminal.

```sh
codex mcp remove sharex
claude mcp remove --scope user sharex
```

If a step fails, ShareX shows completed actions and the failure. Capture and settings writes remain closed after maintenance has started. **Retry** reads the current installation and requests a new confirmation. **Quit** leaves completed steps in place and preserves the remaining files. No step removes evidence folders or requests administrator privileges.
