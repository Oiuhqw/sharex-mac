# Agent capture design

ShareX provides general screenshots and continuous video to local scripts, Claude Code, and Codex. The ordinary menu-bar app owns capture permission, active recordings, and evidence files. Its executable also provides command-line and stdio MCP modes. Those modes dispatch before AppKit startup and connect to the app through a private local socket.

## Decisions

Three design candidates independently recommended this process model. A separate XPC capture helper would add a second executable and more permission and lifecycle rules. Capture inside a command process would end when that process exits. The selected design keeps a single capture owner and one signed application.

Use an app-owned service, a serial video writer, and an off-main storage actor. Keep framework-free request, result, and operation definitions in a shared Swift package that also builds on Linux. Both adapters use the same operation catalog and local connection. ScreenCaptureKit and AVAssetWriter remain in the app. Existing interactive screenshot selection and editing remain in CaptureCoordinator and reuse the underlying screenshot functions.

## Contract

The wire envelope contains version 1, a UUID request ID, an operation name, and arguments. A response contains the same request ID, success state, and either a structured result or an error with a stable code and actionable message. CLI stdout contains JSON. MCP stdout contains JSON-RPC only. Logs use stderr.

Capabilities includes the active session ID so a reconnecting client can find a recording that the app still owns. MCP tool names match operation names. Its optional requestID argument is distinct from the JSON-RPC call ID and remains stable across retries.

Operations are capabilities, targets.list, screenshot, recording.start, recording.status, recording.stop, session.mark, and artifacts.list. Target identifiers come from discovery. Region coordinates use top-left display-local logical points. Responses report actual pixel dimensions. No operation substitutes the frontmost window or mouse display for a lost target.

The app owns private session directories and filenames. Explicit export may copy a completed artifact to a caller-selected destination without replacing an existing file. Request IDs and command content identify retries. The same ID with different arguments returns a conflict. A repeated recording start returns its session. Repeated stops join the same finalization and return the same terminal result.

The service reserves an in-memory request task before durable admission can suspend. The storage actor applies each session mutation atomically. Screenshot completion, markers, and recording finalization cannot overwrite one another's changes through separate reads and writes.

## Lifecycle and limits

Recording states are starting, recording, finalizing, completed, failed, and interrupted. Reserve the single recording slot before asynchronous work. Start acknowledges one complete screen frame accepted by the writer. Later encoding errors remain possible and appear in status. Stop finalizes the container, validates its video track, hashes the file, and commits the artifact manifest before reporting completion.

Allow checkpoint screenshots during recording. Use bounded frame queues and drop under backpressure rather than accumulate memory. Default to silent video at 30 frames per second with a 30-minute duration limit. Bound requests to two hours, two GiB per video, and an output frame within 3840 by 2160 pixels. Preserve aspect ratio and expose actual dimensions. Require disk reserve before and during capture. Report limit termination in the manifest. These limits remain visible in capabilities and may be refined by native measurements.

Write partial output inside the session directory. Publish completed files only after validation. On restart, mark unfinished sessions interrupted. A readable partial movie is still incomplete evidence. Session markers and reported test outcomes remain distinct from capture completion.

## Access and setup

Agent access starts disabled. Capabilities can report setup and permission state without showing a prompt. Other agent operations require access. Settings explains that enabling access authorizes local processes running as the current user. The socket directory is private, the socket checks peer identity, and exclusive ownership prevents competing app processes from replacing a live endpoint.

Settings provides a permission action, CLI installation into the user's bin directory, and copyable Claude Code and Codex registration commands using the resolved application path. The menu shows recording state and a stop action. Revocation and quit use the same bounded finalization path as an agent stop.

## Evaluation

Compile the shared package and exercise protocol behavior on Linux. Run native installed-app E2E on macOS with real display, window, and region content. Independently decode PNGs and video frames, compare known visible state, check beginning and ending coverage, and verify hashes. Exercise screenshot checkpoints, client exit, reconnect, retry, lost targets, disk limits, permission denial, and interrupted recovery. Synthetic display fixtures cannot pass native capture gates.

The current Windows host can run the Linux Swift toolchain. Native build, recording, installed app checks, and both real agent clients remain required before release readiness. No deployment or release publication is part of this work.
