# Agent capture validation

The complete [GitHub run 43413536407](https://github.com/Oiuhqw/sharex-mac/actions/runs/43413536407) passed on 2026-11-13. This includes all 35 agent capture, setup, and actual-client checks, the full regression and performance job, and DMG packaging. The evaluated implementation is `bd0a8e6743b801bea62e05ca63b5d3d941a03367`. The host was an Apple Silicon macOS 15.8.2 VM with Xcode 26.3.

## Native results

| Gate | Passed steps | Evidence |
| --- | ---: | --- |
| Capture API and media | 17 | Real display, window, and region PNG/MP4; checkpoint, retry, reconnect, markers, limits, quit, crash recovery, and target loss |
| Settings and controls | 8 | Enable access, install and update the CLI, execute the wrapper, copy both client commands, stop from the menu, and revoke access during recording |
| Actual agent clients | 10 | Codex 0.169.0 through MCP; Claude Code 2.1.323 through its Bash tool and the ShareX CLI |

The two real clients made 16 tool calls and produced four completed media files. They used zero model turns and no API credentials. Both installed clients also passed ShareX MCP catalog discovery. Claude's native capture path used its shell tool; this does not claim that Claude selected or called ShareX as an external MCP tool.

Across the three native gates, 18 media artifacts completed. Two additional artifact records remained incomplete in the deliberate crash and target-loss cases. The media and client gates independently decoded 16 completed PNG/MP4 files and checked their pixels, dimensions, duration, size, and hashes. The setup gate checked two recording files and their committed hashes while driving the real controls.

The noisy 1 MiB limit case stopped with `byte_limit` and produced a 977,853-byte H.264 MP4 lasting 3.428 seconds. The independent decoder read 40 frames. The static window case held its draw count unchanged through stop and produced two decoded frames covering the full recording interval. Sparse static video is expected.

The installed app matched the Release build's executable hash and passed signature verification. The gate rejected builds containing test capture hooks. Screenshots of the actual Settings page and the captured media are in the run's `agent-capture` artifact. Native capture artifacts expire after three days; the committed scripts reproduce the checks.

## Automated checks and review

The shared agent package passed 38 tests on macOS and 39 on Linux. The extra Linux test checks inherited socket-lock ownership. The Python suite passed 88 tests on macOS. Windows passed 84 and skipped four POSIX-only checks.

The full regression job passed 117 core tests normally and again with AddressSanitizer, interactive capture/editor checks, shortcut recovery, login registration and opt-out, mixed-scale virtual-display checks, and Release resource budgets. Its nine result files contain 929 passed observations and nine `unverifiable` observations. The latter cover uniform virtual-display pixels, compositor conditions, and physical multi-display input. They are not counted as passes. All 35 new agent steps passed without blocked or unverifiable results.

Independent code reviews covered the original feature and the final implementation changes. After fixes, they reported zero actionable findings. Review findings caused atomic request admission and a dedicated static-video case. Native execution also found and drove fixes for interactive MCP input, CLI response IDs, buffered video output, and test-driver readiness.

## Package

The DMG job built Release separately from the same implementation commit. It passed arm64 and test-hook checks, signature verification, a Hardened Runtime launch check, DMG verification, and the simulated quarantine/install/launch probe. No release was published.

The `ShareX-dmg` artifact contains `ShareX.dmg`, its checksum, installation instructions, and resource samples. The downloaded DMG is 1,725,675 bytes. Its independently checked SHA-256 is `3ab05130343cea38cdd69afe058b0e9e30c4354df69950525c6745fffb5b7545`.

## Performance scope

The native media run collected 62 process samples. Peak ShareX RSS was 61,248 KiB and median `ps` CPU was 3.05%. These are diagnostics from this one VM run, not a benchmark or an improvement claim. They exclude WindowServer and other system processes. The workload used a 640 by 480 point fixture, a 1024 by 768 display, a 384 by 288 region, mostly 15 FPS, a static interval, and a noisy byte-limit case. This does not establish 4K or physical-display performance.

The recorder uses native capture and encoding, bounded queues, duration and size limits, and a final file-size check. It reports accepted and dropped frames. The storage actor and PNG encoding operate off the main actor.

The package smoke check collected five warm-idle samples before capture. RSS ranged from 46,016 to 46,112 KiB; each sample reported `ps` CPU at 0.0%. This short observation is not a long-duration idle or energy test.

## Coverage limits

The three reports cover different surfaces. Items labelled `remainingValidation` in the media-only report are resolved by the separate passing setup and actual-client reports where applicable. The following remain outside this evaluation:

- First-use human Screen Recording permission and later macOS TCC revocation. CI pregrants permission on a disposable SIP-disabled runner. Revoking ShareX's own agent-access toggle was tested.
- Actual disk-reserve exhaustion. Atomic storage tests exercise short writes and process interruption; they do not exhaust the native capture volume.
- Physical Retina displays, physical multi-display input, and macOS 14 runtime behavior. The app targets macOS 14; this native run used macOS 15.
- Model selection of tools from a natural-language prompt. Actual client execution was driven through public local protocols without inference.
- Developer ID notarization and first-open Gatekeeper behavior on an ordinary Mac. The CI app is signed ad hoc, consistent with the existing package process; the package job uses a simulated quarantine probe on its disposable runner.

## Reproduce

See [agent setup and use](AGENT-CAPTURE.md) and [actual-client evaluation](AGENT-CLIENT-EVALUATION.md). Dispatch the macOS workflow with `agent_capture_only=false`, `store_artifacts=true`, and `build_package=true` for the complete validation and package path. The workflow does not publish a release.
