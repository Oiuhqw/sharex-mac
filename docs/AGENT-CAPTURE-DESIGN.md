# Agent capture design

ShareX provides general screenshots and continuous video to local scripts, Claude Code, and Codex. The ordinary menu-bar app owns capture permission, active recordings, and evidence files. Its executable also provides command-line and stdio MCP modes. Those modes dispatch before AppKit startup and connect to the app through a private local socket.

## Decisions

Three design candidates independently recommended this process model. A separate XPC capture helper would add a second executable and more permission and lifecycle rules. Capture inside a command process would end when that process exits. The selected design keeps a single capture owner and one signed application.

Use an app-owned service, a serial video writer, and an off-main storage actor. Keep framework-free request, result, and operation definitions in a shared Swift package that also builds on Linux. Both adapters use the same operation catalog and local connection. ScreenCaptureKit and AVAssetWriter remain in the app. Existing interactive screenshot selection and editing remain in CaptureCoordinator and reuse the underlying screenshot functions.

## Contract

The wire envelope contains version 1, a UUID request ID, an operation name, and arguments. A response contains the same request ID, success state, and either a structured result or an error with a stable code and actionable message. CLI stdout contains JSON. MCP stdout contains JSON-RPC only. Logs use stderr.

Capabilities includes the active session ID so a reconnecting client can find a recording that the app still owns. It also reports storage counts: `sessionCount`, `sessionLimit`, and `unreadableSessions`. Capabilities does not start storage, because the CLI uses it as its availability check. `unreadableSessions` is 0 until another operation starts storage. Each MCP tool name is its operation name with `.` replaced by `_`, such as `targets_list`. One function makes that mapping. The CLI words and the wire operation names keep their dots, and a dotted MCP tool name is unknown. The optional MCP `requestID` argument is distinct from the JSON-RPC call ID and remains stable across retries.

A successful MCP screenshot returns the JSON text block first and then the new PNG as an `image/png` block. The image block is scaled to at most 1568 pixels on the longest side. The file on disk stays at full size. If the PNG cannot be read, the result has the text block only. Every other tool returns one text block.

Operations are capabilities, targets.list, screenshot, recording.start, recording.status, recording.stop, session.mark, and artifacts.list. Target identifiers come from discovery. Region coordinates use top-left display-local logical points. Responses report actual pixel dimensions. No operation substitutes the frontmost window or mouse display for a lost target.

The app owns private session directories and filenames. Completed responses provide local file paths for the caller to read or copy. Request IDs and command content identify retries. The same ID with different arguments returns a conflict while the request record exists. A session folder has the ID of the request that created it. After the record expires, a mutating operation that reuses that ID still returns a conflict, and the session does not change. A repeated recording start returns its session. Repeated stops join the same finalization and return the same terminal result. The service stores a failure for replay only when the request left durable state, such as a session or an artifact record. A request refused before work began, such as `busy` or `permission_denied`, leaves no stored response, so the same ID and arguments run again later.

The service reserves an in-memory request task before durable admission can suspend. The storage actor applies each session mutation atomically. Screenshot completion, markers, and recording finalization cannot overwrite one another's changes through separate reads and writes.

## Lifecycle and limits

Recording states are starting, recording, finalizing, completed, failed, and interrupted. Reserve the single recording slot before asynchronous work. Start acknowledges one complete screen frame accepted by the writer. Later encoding errors remain possible and appear in status. Stop finalizes the container, validates its video track, hashes the file, and commits the artifact manifest before reporting completion.

Allow checkpoint screenshots during recording. Use bounded frame queues and drop under backpressure rather than accumulate memory. Default to silent video at 30 frames per second with a 30-minute duration limit. Bound requests to two hours, two GiB per video, and an output frame within 3840 by 2160 pixels. Preserve aspect ratio and expose actual dimensions. Require disk reserve before and during capture. Report limit termination in the manifest. These limits remain visible in capabilities and may be refined by native measurements.

Write partial output inside the session directory. Publish completed files only after validation. On restart, mark unfinished sessions interrupted. A readable partial movie is still incomplete evidence. Session markers and reported test outcomes remain distinct from capture completion.

Recovery skips a session folder that it cannot load. A request for that session returns `storage_failed`, and the message names the folder. A failed storage start is not kept, so the next request tries again. Storage start deletes request records older than seven days. The session limit counts the folders on disk at each check. Settings deletes finished sessions older than 30 days when the user confirms. The age of a session comes from the newest of its end time, its creation time, and the creation time of each artifact. Confirmation deletes only the sessions that the prompt counted. No CLI command or MCP tool deletes evidence.

## Access and setup

Agent access starts disabled. Capabilities can report setup and permission state without showing a prompt. Other agent operations require access. Settings explains that enabling access authorizes local processes running as the current user. The switch stops well-behaved clients only. Any process of the same user can turn access on, because the app is ad-hoc signed and not sandboxed. This limit is accepted for this version.

The socket directory is `sharex-agent` inside the per-user folder that `confstr(_CS_DARWIN_USER_TEMP_DIR)` returns. The app and its helper modes do not read `TMPDIR`, because agent clients change it for the processes that they start. The directory is private, the socket checks peer identity, and exclusive ownership prevents competing app processes from replacing a live endpoint.

Settings provides a permission action, CLI installation into the user's bin directory, and copyable Claude Code and Codex registration commands using the resolved application path. The menu shows recording state and a stop action. Revocation and quit use the same bounded finalization path as an agent stop.

## Evaluation

Compile the shared package and exercise protocol behavior on Linux. Run native installed-app E2E on macOS with real display, window, and region content. Independently decode PNGs and video frames, compare known visible state, check beginning and ending coverage, and verify hashes. Exercise screenshot checkpoints, client exit, reconnect, retry, lost targets, disk limits, permission denial, and interrupted recovery. Synthetic display fixtures cannot pass native capture gates.

The Windows development host runs shared tests through the Linux Swift toolchain. GitHub macOS runners build and evaluate the installed Release app. A separate client gate runs both registration commands in installed Claude Code and Codex clients. It drives Claude Code through MCP with a scripted model stand-in on loopback. No real model chooses a tool in this gate. No deployment or release publication is part of this work.
