# Capture screenshots and video from agents

This feature is in the development source. It is not part of the published 0.1.6 package. Native validation and client compatibility evidence must identify the tested build before release.

ShareX can save PNG screenshots and silent H.264 MP4 recordings of a display, window, or rectangular display region. Claude Code and Codex use the same capture service through MCP. Scripts can use the command line. The menu-bar app owns each recording, so closing a command or reconnecting an agent does not end it.

## Set up once

1. Install this build of ShareX in Applications and open it.
2. Open **Settings > Agents** and enable local agent access.
3. Grant ShareX Screen Recording permission if the page shows that it is missing. Quit and reopen ShareX when macOS requires it.
4. Use the page's copy action for your agent client. Run that command in Terminal.
5. Start a new agent session and ask it to check ShareX capabilities and list capture targets.

Enabling access permits local processes running as your macOS user to capture the screen. Access starts disabled. Disable it in Settings to stop active capture and reject new capture commands. A recording also has a stop action in the ShareX menu.

The registration commands for an app installed at the usual path are:

```sh
claude mcp add --transport stdio --scope user sharex -- /Applications/ShareX.app/Contents/MacOS/ShareX --agent mcp
codex mcp add sharex -- /Applications/ShareX.app/Contents/MacOS/ShareX --agent mcp
```

Settings uses the current app path, including correct quoting for spaces. No Node.js, Python, or FFmpeg installation is needed to run the capture service. The agent client itself must be installed.

MCP exposes `capabilities`, `targets.list`, `screenshot`, `recording.start`, `recording.status`, `recording.stop`, `session.mark`, and `artifacts.list`. Each tool publishes its input schema. Supply the optional `requestID` UUID for mutations that may need a retry after reconnecting.

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

For a retryable mutation, generate a UUID and pass it with `--request-id`. Retry the same request ID and arguments after a lost connection. Reusing that ID with different arguments returns `request_conflict`.

```sh
REQUEST_ID="$(uuidgen)"
~/.local/bin/sharex recording start --target "$TARGET" --request-id "$REQUEST_ID"
```

## Evidence and recording behavior

The app saves evidence in private session directories. `capabilities` reports the session root. A session contains its source, timestamps, markers, capture state, and artifacts. A completed artifact includes its absolute path, dimensions, byte count, and SHA-256. Video artifacts also include duration. Wire dates use Foundation's Codable representation, seconds since 2001-01-01 UTC.

Start returns after the writer accepts the first complete frame. Stop waits for finalization and validation before returning a completed movie. Check `state` and artifact states as well as the command's `ok` field. A successful status query can describe a failed or interrupted recording.

One recording can run at a time. Screenshots can be added during it. Video defaults to 30 frames per second and a 30-minute limit. Requests can set up to two hours and two GiB. Output fits within 3840 by 2160 pixels with even dimensions and a preserved aspect ratio. The recorder reserves disk space and drops frames under encoder pressure instead of growing its queue. Status reports accepted and dropped frame counts.

The app stops on target loss, resize, display geometry change, or scale change. Window movement is allowed. It does not switch to a different target. After an app crash or forced quit, unfinished sessions become interrupted. Partial files do not become completed artifacts.

Agent capture does not open the annotation editor, copy to the clipboard, activate the captured app, or change interactive capture preferences. Audio, pause/resume, GIF, multiple simultaneous recordings, uploads, and remote access are outside this version.

## Troubleshooting

| Result | Action |
| --- | --- |
| `disabled` | Enable local agent access in ShareX Settings. |
| `permission_denied` | Grant ShareX Screen Recording permission, then reopen it if required. |
| `target_not_found` or `target_changed` | List targets again and select the intended source. |
| `busy` | Inspect or stop the active recording before starting another. |
| `request_conflict` | Use the original arguments for a retry, or generate a new request ID for new work. |
| `disk_full` or `storage_failed` | Free space or correct the session directory's permissions, then retry as a new operation. |
| `interrupted` | Preserve the failed session as incomplete evidence and start a new capture. |

Screen Recording permission belongs to the installed app and its signature. Replacing an ad-hoc signed build can require a new permission grant. An SSH session or a machine without a logged-in graphical desktop is not a screen-capture host.

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

Read `result.json` for passed, failed, and blocked checks. Exit code 3 means prerequisites blocked the run. The harness uses a separate visible test app and independently decodes media captured through production APIs. No generated image substitutes for native capture. Its MCP driver proves protocol behavior; it does not prove that an actual Claude Code or Codex session completed the same task.

The manual **Agent capture** workflow builds and installs Release, then runs this harness on an isolated macOS runner. A separate Accessibility driver opens Settings, enables access, installs and updates the CLI, copies both registration commands, stops a real recording, and revokes access during another recording. Each gate writes its own report, so a setup failure cannot hide the media result.

The permission helper is restricted to disposable GitHub runners with SIP disabled. This setup does not validate the human permission flow. Actual client discovery and model-driven capture tasks also require separate evidence. The media harness's resource samples are diagnostics, not a performance comparison.

The workflow also runs [actual-client capture checks](AGENT-CLIENT-EVALUATION.md) through Codex MCP and Claude Code's shell tool without model inference. See the [validation report](AGENT-CAPTURE-VALIDATION.md) for measured results and coverage limits.

## Design references

The [original ShareX recorder](https://github.com/ShareX/ShareX/blob/v22.4.0/ShareX.ScreenRecordingLib/ScreenRecorder.cs) separates start, stop request, and completed output. [ShareX 22.4.0 defaults to native recording](https://github.com/ShareX/ShareX/blob/v22.4.0/ShareX/TaskSettings.cs#L406). This implementation applies those lifecycle ideas with ScreenCaptureKit and AVAssetWriter on macOS.

The [MCP stdio specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#stdio) defines the agent transport. The CLI and MCP adapters share one operation catalog and one app-owned service. See the [architecture design](AGENT-CAPTURE-DESIGN.md) for ownership, retry, and output rules.
