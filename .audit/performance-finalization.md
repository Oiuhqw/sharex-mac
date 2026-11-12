# Performance and RAM assessment

The goal was a quick performance and memory review before finalizing PR 7. The existing native Release measurements show responsive ordinary selection and annotation work. Moving an existing blur through overlapping redactions is the main measured CPU hotspot. This pass found no proven small optimization to apply. Runtime code remains at the fully validated revision, and no speedup or RAM reduction is claimed.

## Evidence and scope

Three standard Apple Silicon macOS runner measurements were available from the implementation campaign. Product code is identical across them; only native test fixtures and startup diagnostics changed. Each report passes the repository's existing performance validator with zero operation errors. This is a baseline assessment across three separate runs, without an A/B implementation comparison.

| Run | Raw measurements | Full workflow result |
| --- | --- | --- |
| [43164563155](https://github.com/Oiuhqw/sharex-mac/actions/runs/43164563155) | [perf.json](performance-finalization/43164563155.json) | Performance passed; an unrelated canvas fixture assertion failed. |
| [43166288929](https://github.com/Oiuhqw/sharex-mac/actions/runs/43166288929) | [perf.json](performance-finalization/43166288929.json) | Performance passed; the startup test's initial-state check failed. |
| [43168138070](https://github.com/Oiuhqw/sharex-mac/actions/runs/43168138070) | [perf.json](performance-finalization/43168138070.json) | Entire workflow passed. |

The large fixture is 3456 by 2234 pixels at 2x. The runner-display fixture is 1024 by 768 at 1x. These are shared 3-core runners with competing load. Timing variations across the three runs do not establish a regression or improvement. WindowServer and GPU memory/CPU are outside the process measurements.

## Interaction CPU

Times below are milliseconds of main-thread CPU for event handling, synchronous display, and layer commit. They exclude blocked time. The first two columns use the latest successful run. The final column shows the range of per-run p95 values across all three runs.

| Operation | Latest p50 | Latest p95 | Three-run p95 range | Samples per run |
| --- | ---: | ---: | ---: | ---: |
| Hover with magnifier | 0.964 | 1.656 | 1.116 to 1.656 | 60 |
| Region selection | 1.716 | 3.113 | 2.584 to 3.113 | 120 |
| Rectangle drawing | 1.091 | 2.026 | 1.727 to 3.203 | 120 |
| New blur drawing | 1.247 | 3.404 | 3.404 to 3.787 | 120 |
| Move an existing blur | 13.588 | 22.257 | 18.649 to 25.068 | 120 |

All three runs passed the existing hover p95 limit of 2 ms. Moving blur can exceed a 60 Hz frame's 16.7 ms budget in this scene. Its latest event-to-next-display-link p95 was 50.196 ms. That timestamp is the earliest presentation opportunity observed by the app; it does not measure completed WindowServer compositing.

## Export and capture wall time

These are wall-clock times, distinct from the CPU table. Each value uses five completed operations in the latest run. The small sample count supports a quick assessment rather than a stable tail-latency estimate. Clipboard, saved PNG, and asynchronous pipeline outputs were decoded and compared for correctness after timing.

| Operation | p50 milliseconds | p95 milliseconds |
| --- | ---: | ---: |
| Capture to overlay on the runner | 61.423 | 61.442 |
| Asynchronous export pipeline | 164.795 | 177.664 |
| Main-thread portion of that pipeline | 32.310 | 34.419 |
| PNG file save | 122.804 | 141.416 |

## Process RAM and ownership

The following values describe the latest run. MiB means 1,048,576 bytes.

| Stage | 3456 by 2234 fixture | 1024 by 768 fixture |
| --- | ---: | ---: |
| Editor, before export | 263.8 to 275.3 MiB | 171.3 to 174.3 MiB |
| After encode and PNG decode | 301.3 to 307.8 MiB | 177.4 to 180.5 MiB |
| After five sessions and settling | 212.2 MiB | 166.4 MiB |
| Change from warmed baseline | +43.4 MiB | -23.4 MiB |

The process lifetime peak was 396.2 MiB. It includes the benchmark's export, decoded-image, and full-size pixel-comparison buffers, so it cannot be used as the editor-only peak. One uncompressed large RGBA frame uses about 29.45 MiB. The two scenarios run sequentially in one process, which also limits interpretation of their baseline changes.

All ten resource sessions released the weakly observed editor and renderer. Their live renderer/layer buffers returned to zero after commit. The five large sessions each used only 3.05 MiB of committed effect-cache storage, below the existing 64 MiB/128-entry cap. A live patch is capped at 16 MiB. Smart Eraser's individual repair image is fixed at 4 KiB.

These checks do not prove every image backing allocation was freed or rule out a leak. The separate memory diagnostic's provider-release fields and cache-clear deltas were written to runner files that were not retained in these logs. Their six passing assertions do not gate provider release. The 26.8 to 48.0 MiB post-session growth seen across the large-fixture runs needs allocation attribution before changing memory policy.

Latest settled idle samples were 0.036 to 0.094 percent of one CPU core after the large fixture, and 0.032 to 0.098 percent after the small fixture. Each scenario has five samples of at least 500 ms. This supports low idle CPU over those short intervals.

## Optimization decision

Moving and resizing already use the same guarded, reduced-resolution blur preview as new blur drawing. Full-resolution rendering returns on mouse-up. Enabling that preview again would add no benefit.

The moving-blur benchmark moves the earliest blur through later committed redactions. Changes to their protection exclusions invalidate cached patches and dirty regions. A committed highlighter also requires the captured source to be redrawn beneath the annotations. This source-level explanation identifies work to profile; the measurements do not assign CPU percentages to those operations.

Three dependency synchronization paths can run during a drag event. Removing repeated scans is a candidate, but no profile shows that they materially contribute to the observed delay. Reducing the effect-cache cap would not affect this measured 3.05 MiB workload and could force more image processing in larger documents. Clearing the shared Core Image context after each capture also needs a RAM/latency comparison first.

The next useful performance experiment is a Time Profiler recording of this exact moving-blur scene, with signposts around dependency synchronization, committed redraw, and patch creation. Retain the provider-release report and inspect allocation ownership in the same diagnostic campaign. Any implementation comparison should then alternate at least five runs per side and retain the privacy and pixel-equivalence gates.

The Explain the Number principle kept CPU, wall time, and validation-buffer RAM separate. Prove It Works kept existing native output checks as the acceptance gate. The Laziness Protocol led to finalizing the tested runtime rather than adding an unmeasured cache or rendering change.

An independent GPT-6 Astra review validated all three measurement files, checked the reported values, and accepted the assessment with no P1 or P2 findings. Its correction to the small-fixture settled RAM delta is included above.

## Recheck the retained measurements

Run `python scripts/validate-perf.py .audit/performance-finalization/43168138070.json` from the repository root. The other two files use the same validator. The product revision remains identical to the [successful full native validation](capture-polish-verification.md), with 929 passing native checks, zero failures, and nine explicit runner/hardware limitations.
