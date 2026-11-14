# Native client evaluation

`scripts/e2e-agent-clients.py` checks the installed Release app through real Claude Code and Codex clients. It does these steps in order:

1. Runs the exact registration command that **Settings > Agents** copies, in the isolated home of each client. The harness replaces only the first word with the path of the pinned client.
2. Checks that `claude mcp list` reports the `sharex` server as connected, and that `codex mcp list` shows it.
3. Drives Codex app-server through an ephemeral thread and the `sharex` entry that `codex mcp add` wrote. Codex calls the ShareX MCP tools.
4. Drives Claude Code's Bash tool through `claude --bare mcp serve`. Bash runs the installed app's `--agent` CLI.
5. Starts the model stand-in, `scripts/agent-model-standin.py`, on 127.0.0.1.
6. Runs one `codex exec` turn against the stand-in and records the tool names that Codex offers a model.
7. Runs one `claude -p` turn against the stand-in. The stand-in makes Claude Code call `targets_list` and then `screenshot` on the evaluation window through MCP. The harness decodes that PNG.

In steps 3 and 4, each client reads capabilities and targets, captures the owned fixture as PNG, starts a real recording, reads status, adds a marker, stops capture, and lists the final artifacts. The shared native verifier decodes the PNG and H.264 MP4, checks fixture colors and stage changes, and compares file size, SHA-256, dimensions, duration, and the persisted manifest. The check also verifies that capture does not change the clipboard, frontmost app, or ShareX windows.

Steps 6 and 7 compare the tool names that each client sends to the model with these expected sets:

| Client | Expected tool names |
| --- | --- |
| Claude Code | `mcp__sharex__capabilities`, `mcp__sharex__targets_list`, and the six other tools in the same form |
| Codex | The namespace `mcp__sharex` with the members `capabilities`, `targets_list`, and the six other tools |

## About the model stand-in

The stand-in replaces the Anthropic and OpenAI model endpoints. It binds 127.0.0.1 only and never forwards a request. It writes each request body to `model-requests.jsonl` in the evidence directory. It does not write request headers.

For Claude Code, the stand-in returns a fixed script. The first reply calls `targets_list`. The second reply calls `screenshot` with the token of the target whose name equals the evaluation window title. The third reply ends the turn. For Codex, the stand-in records the request and returns HTTP 500, so the Codex turn ends after one request. The harness gives each client a placeholder API key that is not a credential.

This check proves that real clients register the server, connect to it, list its tools, and call them through MCP. It does not prove that a real model selects a tool from a natural-language prompt.

## Run

Use an unlocked macOS desktop with Screen Recording permission granted to the installed ShareX Release app and local agent access enabled. Quit ShareX before starting. Pass the actual Release build settings so the harness can compare the installed and built binaries. The driver starts and stops only its own app, fixture, stand-in, and client processes.

Install the pinned official clients into a disposable directory with Node 24:

```sh
npm install --prefix "$RUNNER_TEMP/sharex-agent-clients" --no-audit --no-fund \
  @openai/codex@0.169.0 @anthropic-ai/claude-code@2.1.323
python3 scripts/e2e-agent-clients.py \
  --app /Applications/ShareX.app \
  --build-settings /absolute/path/release-build-settings.json \
  --codex "$RUNNER_TEMP/sharex-agent-clients/node_modules/.bin/codex" \
  --claude "$RUNNER_TEMP/sharex-agent-clients/node_modules/.bin/claude" \
  --out /absolute/path/fresh-client-evidence
```

Client versions must match the pins. Exit `0` means passed, `1` means failed, and `3` means blocked. A non-macOS host cannot pass native capture. The output directory must be empty.

The clients receive fresh configuration and home directories. The environment excludes credentials, shell startup hooks, and inherited agent configuration. Proxy variables point to a closed local port, and only loopback addresses bypass them. No request reaches a real model. Child calls have deadlines. Protocol evidence contains method names, tool names, response identifiers, and error flags. The shared media driver retains the capture and manifest evidence.

For CI artifact uploads, exclude `client-home/**`. It contains disposable client state and is not required to review the result. Keep `result.json`, `events.jsonl`, `model-requests.jsonl`, command and client logs, media verifier output, PNG and MP4 files, and manifest snapshots.

## Sources

- [Codex app-server protocol](https://learn.chatgpt.com/docs/app-server) documents ephemeral threads and `mcpServer/tool/call`.
- [Claude Code as an MCP server](https://code.claude.com/docs/en/mcp#use-claude-code-as-an-mcp-server) documents the built-in tool server and Bash output.
- [Official Codex package metadata](https://registry.npmjs.org/@openai/codex/0.169.0) and [official Claude Code package metadata](https://registry.npmjs.org/@anthropic-ai/claude-code/2.1.323) identify the pinned releases.
