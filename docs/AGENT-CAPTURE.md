# Capture screenshots and video from agents

Agent capture is available in version 0.2.0, build 8. Native validation and client compatibility evidence identify the tested build in the [validation report](AGENT-CAPTURE-VALIDATION.md). The release notes identify the final package and checksum.

ShareX can save PNG screenshots and silent H.264 MP4 recordings of a display, window, or rectangular display region. Claude Code and Codex use the same capture service through MCP. Scripts can use the command line. The menu-bar app owns each recording, so closing a command or reconnecting an agent does not end it.

## Set up once

1. Install this build of ShareX in Applications and open it.
2. Open **Settings > Agents** and enable local agent access.
3. Grant ShareX Screen Recording permission if the page shows that it is missing. Quit and reopen ShareX when macOS requires it.
4. Use the page's copy action for your agent client. Run that command in Terminal.
5. Start a new agent session and ask it to check ShareX capabilities and list capture targets.

Access starts disabled. Disable it in Settings to stop active capture and reject new capture commands. A recording also has a stop action in the ShareX menu.

The registration commands for an app installed at the usual path are:

```sh
claude mcp add --transport stdio --scope user sharex -- /Applications/ShareX.app/Contents/MacOS/ShareX --agent mcp
codex mcp add sharex -- /Applications/ShareX.app/Contents/MacOS/ShareX --agent mcp
```

Settings uses the current app path, including correct quoting for spaces. No Node.js, Python, or FFmpeg installation is needed to run the capture service. The agent client itself must be installed.

## The access switch stops well-behaved clients only

The agent access switch is not a security boundary. A well-behaved agent client respects it. Any other process that runs as your macOS user can turn access on and capture the screen, and macOS shows no prompt. ShareX is ad-hoc signed and is not sandboxed, so it cannot protect this setting from a process of the same user. This is a known limit of this version.

Treat every program that you run as your macOS user as able to capture your screen through ShareX. To remove that ability, remove the ShareX entry from Screen Recording permissions in System Settings. Quitting ShareX is not enough, because the CLI starts the app again.

## Use MCP tools

MCP exposes eight tools: `capabilities`, `targets_list`, `screenshot`, `recording_start`, `recording_status`, `recording_stop`, `session_mark`, and `artifacts_list`. Each tool publishes its input schema. Supply the optional `requestID` UUID for mutations that may need a retry after reconnecting.

An MCP tool name is the operation name with `.` replaced by `_`. The CLI words, such as `sharex targets list`, do not change. The operation names in `capabilities.operations`, such as `targets.list`, do not change either. An MCP call with a dotted name, such as `targets.list`, fails as an unknown tool.

Clients add their own prefix when they show the tools to a model. Claude Code shows `mcp__sharex__targets_list`. Codex shows the namespace `mcp__sharex` with the member `targets_list`. To allow every ShareX tool in Claude Code, use `--allowedTools mcp__sharex`.

A successful `screenshot` call returns two content blocks in this order:

1. A text block that holds the JSON result. It equals `structuredContent`.
2. An `image/png` block that holds the new screenshot, so the model can see the capture.

If the longest side of the screenshot is more than 1568 pixels, the image block holds a copy scaled to 1568 pixels on the longest side. The PNG file on disk stays at full size. If ShareX cannot read the PNG, the result has the text block only, and the call still succeeds. Every other tool returns one text block. The CLI prints the JSON result only.

## Use the command line

Use **Install CLI** in the Agents page to install the `sharex` command in `~/.local/bin`. If that directory is not on your shell's `PATH`, use `~/.local/bin/sharex` directly. Installation refuses to replace an unrelated command.

```sh
~/.local/bin/sharex capabilities
~/.local/bin/sharex targets list
```

Each command prints one JSON response. A successful response has `ok: true` and a `result`. A failed response has `ok: false` and an `error` with a stable `code` and a message.

CLI exit codes are 0 for success, 1 for an operation failure, 2 for invalid arguments or version, 3 for disabled access or missing permission, 4 for a busy recorder, and 5 for a connection or startup deadline. MCP reports tool failures through `isError` and the structured response.

Choose a target token from discovery. Tokens identify this app instance and expire after restart or a target change. Do not store them as long-term window identifiers.

```sh
TARGET='token-from-targets-list'
~/.local/bin/sharex screenshot --target "$TARGET"
~/.local/bin/sharex recording start --target "$TARGET" --duration 300
```

Save the `id` from the recording's `result` as the session ID. Wait for the start response before beginning the work that must appear in the video.

```sh
SESSION='session-id-from-start-result'
~/.local/bin/sharex session mark --session "$SESSION" --label 'Started validation'
~/.local/bin/sharex screenshot --target "$TARGET" --session "$SESSION"
~/.local/bin/sharex session mark --session "$SESSION" --label 'Validation finished' --outcome passed
~/.local/bin/sharex recording stop --session "$SESSION"
~/.local/bin/sharex artifacts list --session "$SESSION"
```

Put stop in your test runner's cleanup or `finally` block. A reported test outcome is a marker. It does not certify the recording or change whether capture completed.

For a display region, add `--region x,y,width,height`. These coordinates are logical points measured from the selected display's top-left corner. Window targets do not accept a region. Artifact metadata gives the output dimensions in pixels.

```sh
~/.local/bin/sharex screenshot --target "$TARGET" --region 100,80,800,600
```

## Retry a request

For a retryable mutation, generate a UUID and pass it with `--request-id`. After a lost connection, retry with the same request ID and the same arguments. ShareX returns the stored result and does not do the work twice. If you reuse the ID with different arguments, ShareX returns `request_conflict`.

```sh
REQUEST_ID="$(uuidgen)"
~/.local/bin/sharex recording start --target "$TARGET" --request-id "$REQUEST_ID"
```

ShareX stores a result for a request ID only when the request created a session or an artifact. If ShareX refuses a request before work begins, it stores nothing for that ID. Examples are `busy`, `permission_denied`, `disk_full`, `limit_reached`, and a `target_not_found` that occurs before capture starts. Correct the cause, then retry with the same request ID. The request then runs.

If ShareX accepted a request and an app restart interrupted it, the request ID returns `interrupted`. That request never runs again. Use a new request ID for new work.

## Evidence and recording behavior

The app saves evidence in private session directories. `capabilities` reports the session root. A session contains its source, timestamps, markers, capture state, and artifacts. A completed artifact includes its absolute path, dimensions, byte count, and SHA-256. Video artifacts also include duration. Wire dates use Foundation's Codable representation, seconds since 2001-01-01 UTC.

Start returns after the writer accepts the first complete frame. Stop waits for finalization and validation before returning a completed movie. Check `state` and artifact states as well as the command's `ok` field. A successful status query can describe a failed or interrupted recording.

One recording can run at a time. Screenshots can be added during it. Video defaults to 30 frames per second and a 30-minute limit. Requests can set up to two hours and two GiB. Output fits within 3840 by 2160 pixels with even dimensions and a preserved aspect ratio. The recorder reserves disk space and drops frames under encoder pressure instead of growing its queue. Status reports accepted and dropped frame counts.

The app stops on target loss, resize, display geometry change, or scale change. Window movement is allowed. It does not switch to a different target. After an app crash or forced quit, unfinished sessions become interrupted. Partial files do not become completed artifacts.

Agent capture does not open the annotation editor, copy to the clipboard, activate the captured app, or change interactive capture preferences. Audio, pause/resume, GIF, multiple simultaneous recordings, uploads, and remote access are outside this version.

## Manage stored captures

ShareX keeps each session folder until you delete it. A screenshot without `--session` is a session of its own. No CLI command and no MCP tool deletes captures, so an agent client cannot delete evidence.

To delete old captures:

1. Open **Settings > Agents**.
2. Click **Delete Old Captures…**.
3. Read the confirmation text, `Delete N captures older than 30 days?`.
4. Click **Delete** to delete those captures, or click **Cancel** to keep them.

The status text in the same section shows `N captures stored`. **Delete** removes each finished session (`completed`, `failed`, or `interrupted`) that ended more than 30 days ago. If a session has no end time, ShareX uses its creation time. **Delete** never removes the active recording, a session that is not finished, or a folder that ShareX cannot read.

ShareX limits the number of stored sessions. `capabilities` reports the counts in `storage`:

- `sessionCount` is the number of stored sessions.
- `sessionLimit` is the maximum number of sessions.
- `unreadableSessions` is the number of session folders that ShareX skipped.

When the limit is reached, a new capture returns `limit_reached`. Delete old captures in Settings, or delete session folders in the session root yourself. ShareX counts the folders on disk at each check, so you do not need to restart it.

When ShareX starts, it deletes retry records that are older than 7 days. These records are a retry cache, not evidence. Session folders and their manifests stay.

If a session folder has the wrong mode, the wrong owner, or a bad manifest, ShareX skips that folder when it starts. The other sessions keep working. A request that names the skipped session returns `storage_failed`, and the message names the folder. Correct the folder, then retry. If storage fails to start, ShareX tries again on the next request.

## Troubleshooting

| Result | Action |
| --- | --- |
| `disabled` | Enable local agent access in ShareX Settings. |
| `permission_denied` | Grant ShareX Screen Recording permission, then reopen it if required. Retry with the same request ID. |
| `target_not_found` or `target_changed` | List targets again and select the intended source. |
| `busy` | Wait for the active recording to end, or stop it. Then retry. The same request ID works, because ShareX stores no result for `busy`. |
| `request_conflict` | Use the original arguments for a retry, or generate a new request ID for new work. |
| `limit_reached` | Delete old captures in **Settings > Agents**, or delete session folders yourself. Then retry. You do not need to restart ShareX. |
| `disk_full` | Free disk space, then retry. The same request ID works. |
| `storage_failed` | Read the folder path in the message. Make sure that your user owns the folder and that its mode is 700, for example with `chmod 700 '/path/from/message'`. Then retry. Other sessions keep working. |
| `interrupted` | Preserve the failed session as incomplete evidence and start a new capture. |

Screen Recording permission belongs to the installed app and its signature. Replacing an ad-hoc signed build can require a new permission grant. An SSH session or a machine without a logged-in graphical desktop is not a screen-capture host.

The CLI and MCP modes reach the app through a socket in a private per-user folder. To find the socket, run:

```sh
echo "$(getconf DARWIN_USER_TEMP_DIR)sharex-agent/agent.sock"
```

The path does not depend on `TMPDIR`. Agent clients can change `TMPDIR` for the processes that they start, and the CLI still finds the app.

## Validate a build

Run the shared protocol and transport tests with:

```sh
swift test --package-path Packages/ShareXAgent
```

The native harness requires an installed Release app, its matching `xcodebuild -showBuildSettings -json` output, pregranted capture permission, enabled agent access, and a logged-in desktop. It refuses test-enabled app builds. Close the running ShareX instance so the harness can own its processes.

```sh
bash scripts/e2e-agent-capture.sh \
  --app /Applications/ShareX.app \
  --build-settings /absolute/path/agent-build-settings.json \
  --out /absolute/path/new-evidence-directory
```

Read `result.json` for passed, failed, and blocked checks. Exit code 3 means prerequisites blocked the run. The harness uses a separate visible test app and independently decodes media captured through production APIs. No generated image substitutes for native capture. Its MCP driver proves protocol behavior. The client gate covers real Claude Code and Codex.

The manual **Agent capture** workflow builds and installs Release, then runs this harness on an isolated macOS runner. A separate Accessibility driver opens Settings, enables access, installs and updates the CLI, copies both registration commands, stops a real recording, revokes access during another recording, and deletes old captures. Each gate writes its own report, so a setup failure cannot hide the media result.

The permission helper is restricted to disposable GitHub runners with SIP disabled. This setup does not validate the human permission flow. The media harness's resource samples are diagnostics, not a performance comparison.

The workflow also runs [actual-client checks](AGENT-CLIENT-EVALUATION.md). They run both registration commands, check that Claude Code connects to the ShareX MCP server, and drive Claude Code through MCP with a scripted model stand-in on loopback. No real model request and no credential is used. See the [validation report](AGENT-CAPTURE-VALIDATION.md) for the run of the commit under test and the coverage limits.

## Design references

The [original ShareX recorder](https://github.com/ShareX/ShareX/blob/v22.4.0/ShareX.ScreenRecordingLib/ScreenRecorder.cs) separates start, stop request, and completed output. [ShareX 22.4.0 defaults to native recording](https://github.com/ShareX/ShareX/blob/v22.4.0/ShareX/TaskSettings.cs#L406). This implementation applies those lifecycle ideas with ScreenCaptureKit and AVAssetWriter on macOS.

The [MCP stdio specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#stdio) defines the agent transport. The CLI and MCP adapters share one operation catalog and one app-owned service. See the [architecture design](AGENT-CAPTURE-DESIGN.md) for ownership, retry, and output rules.
