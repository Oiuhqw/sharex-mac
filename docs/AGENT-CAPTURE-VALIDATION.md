# Agent capture validation

Validation run: PENDING

The line above names the GitHub Actions run of the **Agent capture** workflow for the commit under test. That run is the evidence for this report. Its job log prints the `result.json` of each gate, with the passed, failed, and blocked steps and the session and artifact counts. If the run stores artifacts, the `agent-capture-<commit SHA>` artifact holds the media, manifests, and logs for three days. This report does not copy counts from a run, because each commit changes them.

## Corrections to earlier versions

Earlier versions of this report made three claims that the evidence did not support.

- The report cited run 43413536407 on commit `bd0a8e6`. At that commit the project was version 0.1.6, build 7, not the 0.2.0 tree. The counts from that run do not describe 0.2.0.
- The report said that both installed clients passed ShareX MCP catalog discovery. Claude Code did not. The harness listed Claude Code's own tools, `Bash`, `Read`, and `Edit`, through `claude --bare mcp serve`. ShareX ran through Claude's Bash tool and the CLI, never through Claude Code's MCP client.
- The report said that the registration items were resolved. The harness never ran either registration command. The setup gate compared the copied text only. The Codex check wrote its own configuration with a server named `sharex_evaluation`.

The client gate now runs both registration commands and connects Claude Code to the ShareX MCP server. See [actual agent clients](#actual-agent-clients).

## Gates

The workflow runs three gates on a disposable `macos-15` runner. Each gate writes its own report.

| Gate | Script | What it checks |
| --- | --- | --- |
| Settings and controls | `scripts/e2e-agent-setup.py` | Enables access, installs and updates the CLI, runs the wrapper, and copies both registration commands. Stops a recording from the menu and revokes access during a recording. Deletes old captures with **Delete Old Captures…** and checks that **Cancel** deletes nothing. Checks the text that Settings shows when no capture is old. |
| Capture API and media | `scripts/e2e-agent-capture.py` | Real display, window, and region PNG and MP4 through the CLI and MCP. Checkpoint, retry, reconnect, markers, limits, quit, crash recovery, and target loss. Underscore MCP tool names, the screenshot image block, and the storage counts. A busy start that runs again with the same request ID, an unreadable session folder, and a nested socket frame. |
| Actual agent clients | `scripts/e2e-agent-clients.py` | Both registration commands, `claude mcp list`, Codex app-server calls through its registered entry, and Claude Code Bash calls to the CLI. The tool names that each client offers a model, and Claude Code MCP calls driven by a scripted model stand-in. |

The media and client gates decode each completed PNG and MP4 with an independent verifier. They check pixels, dimensions, duration, size, and hashes against the committed manifest. The setup gate checks its recording files and their committed hashes. Artifacts of the deliberate crash and target-loss cases must stay incomplete.

The installed app must match the Release build's executable hash and pass signature verification. The gates reject builds that contain test capture hooks.

## Actual agent clients

The client gate runs the exact registration commands that Settings copies. `claude mcp list` must report the ShareX server as connected. Claude Code must offer the model the eight tools in the form `mcp__sharex__targets_list`. Codex must offer the namespace `mcp__sharex` with members such as `targets_list`. A scripted stand-in model on 127.0.0.1 makes Claude Code call `targets_list` and then `screenshot` through MCP, and the gate decodes the PNG. See the [client evaluation](AGENT-CLIENT-EVALUATION.md) for each step.

## Automated checks

Before it builds the app, the workflow runs the Python harness unit tests and the shared agent package tests:

```sh
python3 -m unittest discover -s scripts/tests -v
swift test --package-path Packages/ShareXAgent
```

The job log of the validation run gives the counts. The full regression job in `.github/workflows/macos.yml` covers the interactive app. This report does not cover it.

## Package

The DMG job is separate from these gates. The release notes identify each package and its checksum.

## Performance scope

The media gate samples ShareX RSS and `ps` CPU. It writes the samples to `metrics.json` and a summary to the `statistics` object of its `result.json`. These are diagnostics from one VM run, not a benchmark or an improvement claim. They exclude WindowServer and other system processes. The workload uses a 640 by 480 point fixture, a 1024 by 768 display, a 384 by 288 region, mostly 15 FPS, a static interval, and a noisy byte-limit case. This does not establish 4K or physical-display performance.

The recorder uses native capture and encoding, bounded queues, duration and size limits, and a final file-size check. It reports accepted and dropped frames. The storage actor and PNG encoding operate off the main actor.

## Coverage limits

Each gate's `remainingValidation` list names what that gate does not cover. The other gates cover some of those items. The following remain outside this evaluation:

- First-use human Screen Recording permission and later macOS TCC revocation. CI pregrants permission on a disposable SIP-disabled runner. Revoking ShareX's own agent-access toggle was tested.
- The access switch as a security boundary. It stops well-behaved clients only. See [the access limit](AGENT-CAPTURE.md#the-access-switch-stops-well-behaved-clients-only).
- Actual disk-reserve exhaustion. Atomic storage tests exercise short writes and process interruption. They do not exhaust the native capture volume.
- Physical Retina displays, physical multi-display input, and macOS 14 runtime behavior. The app targets macOS 14. The native run uses macOS 15.
- Tool selection by a real model. The stand-in model follows a fixed script, `targets_list` and then `screenshot`. For Codex, the gate records the offered tool names only. Codex model-driven calls are not exercised.
- Developer ID notarization and first-open Gatekeeper behavior on an ordinary Mac. The CI app is signed ad hoc, consistent with the existing package process. The package job uses a simulated quarantine probe on its disposable runner.

## Reproduce

See [agent setup and use](AGENT-CAPTURE.md) and [actual-client evaluation](AGENT-CLIENT-EVALUATION.md). Dispatch the macOS workflow with `agent_capture_only=false`, `store_artifacts=true`, and `build_package=true` for the complete validation and package path. The workflow does not publish a release.
