# Late-noise diagnostic

Issue 10 needs a recording fix that passes the full original Mac E2E workflow. This diagnostic tests whether first noise still precedes a long source interval after ordinary capture has run for one second. It is a separate diagnostic branch and must not enter PR 11.

The preceding comparison at `403abad980110515c3e730ebd270418211a32827` completed four arms with zero collection errors. In the first post-noise second, its before arms had maximum complete-source intervals of 580.0 and 425.7 ms. Its immediate-after arms had maxima of 644.3 and 137.2 ms in that window. Noise began only 27.6 and 98.1 ms after the first capture PTS in those after arms. Stream startup and the first noise transition were still close together. Two observations per arm do not establish a failure rate or speed difference.

`frame_gap_replay=true` now selects `frame-gap-startup.py --comparison late-noise`. Dispatch retains ten inputs. The original setup UI runs once, followed by this fixed ABBA sequence:

| Arm | Target sink | First noise transition |
| --- | --- | --- |
| 1 | Metadata only | Before MCP start |
| 2 | Metadata only | At the first status-poll boundary at least one second after the first complete-frame acknowledgement |
| 3 | Metadata only | At the first status-poll boundary at least one second after the first complete-frame acknowledgement |
| 4 | Metadata only | Before MCP start |

Each arm starts a fresh app and fixture process. It executes the same 15 native prefix steps, seven movie decodes, and four PNG decodes. The duration-region movie and its decode remain the immediate predecessor. The fixture stays synchronous. BGRA, queue depth three, 15 FPS, the heartbeat, and the exact 1 MiB, 30-second window request remain unchanged. No Swift or fixture source changes belong to this split.

Both arms start the native terminal loop immediately after acknowledgement. The diagnostic CLI override records each target poll boundary and delegates to the unchanged native CLI. The native loop waits 100 ms after each response. In a late arm, the override sends one noise command at the first eligible boundary, waits for its response, then launches that boundary's status command. No control thread runs in parallel. No one-second sleep delays the first poll. The noise command delays only the status launch at its boundary. The report retains that delay.

The metadata sink remains unchanged. Its fixed three-second observation starts at the first complete callback. It creates no encoder, copies no pixels, retains no sample, accepts no encoder frame, and publishes no movie. The outcome remains `diagnostic_metadata_complete`. A slow command can leave too little post-noise evidence. The driver marks that arm incomplete and retains the raw data. It never extends the observation or waits for a better cadence before it requests noise.

These qualification limits are fixed before the Mac run. They determine whether a late arm answers the diagnostic question. They do not change the production media gate.

| Required evidence in a late arm | Fixed limit |
| --- | --- |
| Noise command eligibility | Acknowledgement plus 1.0 second, at the first eligible poll boundary |
| Complete callbacks before the actual first noisy draw | At least 8 |
| Complete-source PTS span before that draw | At least 0.75 second |
| Every full adjacent complete-source PTS interval before that draw | Positive and no more than 0.2 second |
| Age of the last complete-source PTS at that draw | No more than 0.2 second |
| Capture coverage after that draw | Through at least 1.0 second after it |

Pre-noise qualification uses callbacks that finished before the actual first noisy draw entry, with PTS before that draw. It uses all such complete callbacks, without selecting a favorable suffix. The analysis also reports the last complete callback exit age. An arm with eight early frames followed by silence cannot qualify. Missing cadence, timing, coverage, or unique noise-command evidence makes the collection incomplete. Long intervals remain in the raw trace and report.

`comparison.json` records the acknowledgement, fixed deadline, triggering poll boundary, noise request, first noisy draw, and control response separately. It also retains every target poll boundary and the actual status process launches. `preNoiseCapture` reports complete-source and all-source PTS intervals, their separate maxima, and callback status counts. All-source intervals include every callback with a PTS. Complete-source intervals use valid screen callbacks with an image and status zero. Idle callbacks cannot silently split a complete-frame gap.

The report retains full source intervals that cross the noise transition. It does not clip their start to the first noisy draw. It reports the first complete-source and all-source interval above 500 ms, including each endpoint relative to noise and whether the interval is before, crossing, or after noise. The post-noise window keeps full intervals that overlap its first second, including an interval that ends after that second. `callbackEntryIntervals` includes every callback status. `completeCallbackEntryIntervals` includes only complete callbacks. Fixture operations, draws, heartbeats, and raw callbacks remain available.

These interpretation rules are fixed before the run:

| Observed result | Supported next decision | Limit |
| --- | --- | --- |
| Both qualified late arms have a complete-source interval above 500 ms that crosses or follows noise | Investigate first-noise source or presentation work after ordinary capture. | Temporal order does not identify a private WindowServer mechanism. A crossing interval began before noise and must be described that way. |
| Both qualified late arms have no interval above 500 ms overlapping the first post-noise second, while a before arm reproduces one | Narrow the next investigation to startup dependence or its interaction with noisy content. | This does not identify a production fix or exclude prior shared resources and CLI work. |
| The late arms disagree, no before arm reproduces, or any arm is incomplete | Preserve the evidence and make no clean causal decision. | Two observations per arm cannot estimate reliability. |

The earlier comparisons remain available as `--comparison noise-timing` and `--comparison sinks`. The original independent decoder and its 500 ms gate are unchanged. After a separate supported production fix, run the full original GitHub Mac E2E workflow. Local Python contracts and diagnostic completion do not satisfy that evaluation.
