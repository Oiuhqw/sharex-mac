# Bitmap content diagnostic

Issue 10 needs a recording fix that passes the original full Mac E2E workflow. This separate diagnostic tests whether high-entropy changing RGB content is necessary for the source gap. It does not supply a production fix for PR 11.

The late-noise run at `5771a7eb656ffef2593f5c925b9c0b739a285a13` completed all four arms. One late arm had a 648.593 ms all-source gap after 13 complete callbacks spanning 1.098 seconds before noise. Its gap began 72.673 ms after the first noisy draw and ended 721.266 ms after that draw. The other late arm was clean. This disagreement prevents a clean paired timing claim. The observed late gap shows that the gap is not restricted to initial stream startup. A 403 ms complete-frame interval in the fourth arm contained idle callbacks and was not source silence.

`frame_gap_replay=true` selects `frame-gap-startup.py --comparison bitmap-content` and retains ten dispatch inputs. The fixed sequence is original, constant, constant, original. All four targets use metadata and enable noise before `recording.start`. Each fresh app and fixture executes the original 15 prefix steps, seven movie decodes, and four PNG decodes. The duration-region movie decode remains the immediate predecessor. BGRA, queue depth three, 15 FPS, the three-second metadata observation, and the original native and decoder 500 ms gates remain unchanged. There is no warmup or extra wait.

The fixture reads `SHAREX_FRAME_GAP_BITMAP_COMPONENT_MASK` once when it creates its view. Original content uses 255 and constant content uses 0. Every noisy draw allocates the same 143,360 bytes and executes all 35,840 LCG iterations. The loop applies the mask to the three RGB bytes. The unused fourth byte remains 255. Both conditions create the same 640 by 56 RGBX DeviceRGB image with 8 bits per component, 32 bits per pixel, 2,560 bytes per row, and `noneSkipLast`. Both draw it without interpolation into the original 640 by 57.6 point rectangle. The rest of the fixture still animates. Constant refers only to the bitmap's RGB bytes.

Every successful bitmap draw records scalar evidence after `CGContext.draw` returns. Its nested `bitmap` record contains the mask, actual image layout, destination rectangle, RGB nonzero count, final LCG seed, and draw entry and exit uptime. The containing draw records its tick. All noisy draws must contain this proof, and no non-noisy prefix draw may contain it. The analyzer requires zero nonzero RGB bytes in the constant condition and a positive count in the original condition. After capture, it recalculates the final seed and exact nonzero count from the tick to check the full loop. The same count and trace work runs in both conditions. There is no pixel readback, image hash, or GPU fence. A returned draw proves submission through this path, not completion by the compositor or display.

The analyzer checks the selected content mode, exact bitmap layout and byte count, scaled rectangle, unique noise command, and before-start timing. It requires the same fixture source, fixture executable, and installed app executable across all arms. The original per-arm fixture compilation remains in the prefix. Missing or changed binaries make collection incomplete. Existing draw and operation traces keep their 100,000-entry bounds and overflow counts. Any overflow makes collection incomplete.

The report retains the first successful bitmap draw, all-source and complete-source intervals separately, full intervals across the first draw, callback entry times, heartbeats, and fixture operation spans. Idle callbacks can split an all-source interval while leaving a long complete-frame interval. These remain separate observations. Long gaps are diagnostic data and never become a successful production E2E result. Metadata accepts no encoder frames and publishes no movie. Constant content is never forced through the byte-limited MP4 test.

These interpretation rules are fixed before dispatch.

| Observation with complete evidence | Supported conclusion |
| --- | --- |
| A constant arm reproduces an all-source gap above 500 ms | High-entropy changing RGB content is not necessary for that gap. A single event does not establish a stable comparative effect. |
| Both original arms reproduce, and both constant arms remain clean | The result supports a content-dependent presentation boundary. It does not identify a specific compositor, GPU, or color-processing mechanism. |
| The repetitions disagree, all arms are clean, or any arm is incomplete | There is no clean paired causal claim. Preserve the raw evidence. |

The next investigation uses a system profile to locate the unresolved presentation or source work. Timing alone does not justify a production delay, pixel-format change, copied buffer, discarded frame, or relaxed gate. The earlier `sinks`, `noise-timing`, and `late-noise` comparisons remain available through the script with their original timing and content.

Local Python contracts validate orchestration and evidence rejection. Windows cannot compile or execute this AppKit fixture. A reviewed Mac diagnostic must compile the real fixture and collect all four variants. A later production fix must pass the entire original Mac E2E workflow, including decoded media, actual clients, and maintenance. Diagnostic completion is not that evaluation.

The implementation checkpoint covers one fixture, one comparison driver, workflow selection, and focused contracts. The Model the Domain principle keeps arm, timing, and content in one comparison table. Parent review precedes any push or dispatch.
