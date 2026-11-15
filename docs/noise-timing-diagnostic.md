# First-noise timing diagnostic

Issue 10 needs a recording fix that passes the full original Mac E2E workflow. This diagnostic separates stream startup from the fixture's first noise draw. It is not a production fix or decoded-video coverage.

The preceding sink comparison at `0fa8455`, Mac run `43741275374`, collected four valid arms with zero collection errors. The writer arms had first source intervals of 646.526 and 509.634 ms. The metadata arms had intervals of 580.870 and 525.995 ms. Metadata callbacks took about 0.11 and 0.14 ms while fixture draws and recorder heartbeats continued. The current capture's writer and retained sample are therefore not necessary for that gap. Earlier writers, decoder activity, source presentation, shared graphics resources, and SCK startup remain in the experiment.

This earlier split remains available through `frame-gap-startup.py --comparison noise-timing`. `frame_gap_replay=true` now selects the [late-noise diagnostic](late-noise-diagnostic.md). Setup UI runs once before the fixed sequence:

| Arm | Target sink | First noise transition |
| --- | --- | --- |
| 1 | Metadata only | Before MCP start |
| 2 | Metadata only | Immediately after the first complete-frame acknowledgement |
| 3 | Metadata only | Immediately after the first complete-frame acknowledgement |
| 4 | Metadata only | Before MCP start |

Each arm starts fresh app and fixture processes and executes the original 15-step native prefix. The prefix includes seven movie decodes and four PNG decodes inline. The duration-region recording and decode remain the immediate predecessor. Every arm uses the original synchronous fixture, BGRA, queue depth three, 15 FPS, the heartbeat, and the same exact 1 MiB, 30-second window target request. The async fixture publication fix is absent.

In a before arm, the existing noise control finishes before MCP start. In an after arm, MCP starts while the fixture draws its ordinary animated pattern. The driver requests noise as soon as the metadata acknowledgement returns. It adds no wait or noise warmup. The metadata sink stays unchanged in all four arms. It does no encoder, sample retention, pixel lock, or pixel copy work. Its three-second observation starts at the first complete callback. It ends with `diagnostic_metadata_complete`, zero accepted frames, and no movie or completed artifact.

`comparison.json` retains first capture PTS, first noisy draw entry uptime, first source intervals, callback data around noise, and intervals that overlap the first post-noise second. A crossing interval keeps its full duration. This avoids hiding a gap that starts before noise or ends after that second. The report includes the maximum PTS, displayTime, and callback interval in that window. It also records fixture operation spans, draw duration and cadence, heartbeats, and the maximum fixture operation span during the target capture. Raw traces retain all operations and callbacks.

The first noisy draw may follow the first PTS in an after arm. Its negative `firstNoisyDrawToFirstPTSSeconds` is expected. Analysis checks that the first noise command is unique and the first noisy draw occurs during that command. In after arms, the command must follow the complete-frame acknowledgement. It requires capture data within the first post-noise second and through its end. Missing evidence, overflow, stream errors, a wrong writer count, a wrong timing order, or target media makes the collection incomplete. A long source interval remains diagnostic data.

The after arm waits for the noise control response before its first CLI status launch. The report measures noise control duration and acknowledgement-to-status delay. Later status polls retain the original 100 ms delay after each response. This launch shift is an induced timing difference, not proof of a source mechanism. Two observations per arm cannot establish a failure rate.

| Observed result | Supported interpretation | Remaining limit |
| --- | --- | --- |
| The long interval moves with first noise in the after arms | First-use source or presentation work deserves the next split. | This does not identify a private WindowServer mechanism. |
| The long interval occurs only when the stream starts noisy | A startup and content interaction deserves the next split. | CLI launch timing and prior shared resources remain possible influences. |
| Neither arm reproduces, or the fixture stalls | No clean causal decision. Preserve the timings and failures. | A passing collection does not close issue 10. |

The existing sink comparison remains available with `--comparison sinks`. The original media verifier and its 500 ms decoded-frame gate are unchanged. After a separate production fix, run the complete original Mac E2E workflow. Local contracts and this diagnostic do not replace that evaluation.
