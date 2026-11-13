# Native client evaluation

`scripts/e2e-agent-clients.py` checks the installed Release app through two real client execution paths:

- Codex app-server routes the eight ShareX MCP tools through an ephemeral test thread.
- Claude Code exposes its Bash tool through `claude --bare mcp serve`. Bash executes the installed app's `--agent` CLI entry point.

Each client reads capabilities and targets, captures the owned fixture as PNG, starts a real recording, reads status, adds a marker, stops capture, and lists the final artifacts. The shared native verifier decodes the PNG and H.264 MP4, checks fixture colors and stage changes, and compares file size, SHA-256, dimensions, duration, and the persisted manifest. The check also verifies that capture does not change the clipboard, frontmost app, or ShareX windows.

This check uses no model prompt or inference. It proves actual tool execution and local client compatibility. It does not prove that an LLM will select a tool from a natural-language prompt. Claude's MCP server exposes its built-in tools; this route does not claim Claude invoked ShareX as an external MCP tool.

## Run

Use an unlocked macOS desktop with Screen Recording permission granted to the installed ShareX Release app and local agent access enabled. Quit ShareX before starting. Pass the actual Release build settings so the harness can compare the installed and built binaries. The driver starts and stops only its own app, fixture, and client processes.

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

The clients receive fresh configuration and home directories. The environment excludes credentials, shell startup hooks, and inherited agent configuration. Only local protocol methods run; no model turn starts. Child calls have deadlines. Protocol evidence contains method names, tool names, response identifiers, and error flags. The shared media driver retains the capture and manifest evidence.

For CI artifact uploads, exclude `client-home/**`. It contains disposable client state and is not required to review the result. Keep `result.json`, `events.jsonl`, command and client logs, media verifier output, PNG/MP4 files, and manifest snapshots.

## Sources

- [Codex app-server protocol](https://learn.chatgpt.com/docs/app-server) documents ephemeral threads and `mcpServer/tool/call`.
- [Claude Code as an MCP server](https://code.claude.com/docs/en/mcp#use-claude-code-as-an-mcp-server) documents the built-in tool server and Bash output.
- [Official Codex package metadata](https://registry.npmjs.org/@openai/codex/0.169.0) and [official Claude Code package metadata](https://registry.npmjs.org/@anthropic-ai/claude-code/2.1.323) identify the pinned releases.
