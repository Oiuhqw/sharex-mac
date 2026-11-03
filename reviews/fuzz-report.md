# Fuzz report (ShareXCore)

## Harness 1: seeded XCTest properties (`Tests/ShareXCoreTests/FuzzTests.swift`)
SplitMix64 PRNG. `FUZZ_SEED` (default 0x5AE7C0DE) and `FUZZ_SCALE` env vars. Each failure logs the seed and the op trace.

| Property | Iterations (scale 1) |
|---|---|
| pixel/point round trip | 40,000 |
| cocoa flip, clamp, cropDrag | 20,000 |
| StitchLayout | 10,000 |
| EffectMath | 10,000 |
| editor random op sequences (up to 60 ops each; undo/redo/history invariants) | 4,000 |
| undo limit | 20 |
| settings decode (random bytes, bit flips, wrong types, truncation) | 30,000 |
| **Total** | **114,020** |

Soak: seeds 1, 2, 3, 42 and 1337 at `FUZZ_SCALE=10`, about 1.14M iterations each (about 5.7M total). All passed after the fixes.

## Harness 2: libFuzzer + ASan on settings decoding (`Fuzz/SettingsFuzzer.swift`)
`LLVMFuzzerTestOneInput` decodes the input, re-encodes it, checks the round trip and calls `resolve`. 1,914,402 executions in 181 s, no crash after the fix. Corpus at `/tmp/fz` (box only).
Build: `swiftc -sanitize=fuzzer,address -parse-as-library -O -L/tmp/fuzzlib Fuzz/SettingsFuzzer.swift <core files>`. `/tmp/fuzzlib` holds a `libstdc++.so` symlink because the Linux toolchain needs it.

## Findings
| # | Kind | Finding | Fix | Test |
|---|---|---|---|---|
| 1 | Crash | swift-foundation `JSONDecoder` traps (`try!`, `unescapedControlCharacterInString`) on a raw control character in an object key. Reproduced standalone; this is an upstream bug. Likely Linux-only, since Darwin uses a different decoder, but this is unverified. | `Settings.decode` pre-validates with `JSONSerialization` and requires a top-level object. | `SettingsCrashRegressionTests` |
| 2 | Logic | Selection pointed at a removed mark after `setText("")`. | `dropStaleSelection()` | `EditorFuzzRegressionTests` |
| 3 | Logic | A second `addText` overwrote the pending empty mark, which leaked. | `addText` commits pending text first. | same |
| 4 | Logic | `applyStyle` on another mark captured the pending empty text into history. | Commit first; style changes on the pending mark itself update it without history. | same |

Three harness bugs were fixed during development (wrong redo-all invariant, wrong cocoa reference, and the unreliable corelibs `CGRect.contains`, replaced by a `covers` helper). None of these were product bugs.

## Round 2 — final validation (2026-11-03, UTC+8)

### Property fuzzing (XCTest, `FUZZ_SCALE=10`, new seeds)
| Seed | Iterations | Result |
|---|---|---|
| 20261103 | ~1.44M (geometry/pixel round-trip 400k, cocoa clamp, stitch, effect maths, editor random sequences, undo limit, settings decode 300k, **new** sanitize property 300k) | 8/8 pass, 74 s |
| 3141592653 | ~1.44M | 8/8 pass, 73 s |
| **Total** | **~2.88M** | 0 failures |

New property `testSanitizedSettingsAreInRangeIdempotentAndRoundTrip`: random extreme options and styles (±Int.max, ±greatestFiniteMagnitude, ±1e6) → decode(encode) gives in-range values; `sanitized()` is idempotent; the round trip is stable.

### libFuzzer + ASan (`-sanitize=fuzzer,address`, `SWIFT_BACKTRACE=enable=no`, `-artifact_prefix=/tmp/fzart/`)
| Target | Seed | Time | Execs | Coverage | Result |
|---|---|---|---|---|---|
| SettingsFuzzer (pre-fix code) | 20261103 | 331 s | 3,449,495 | cov 414 | no crash |
| SettingsFuzzer (post-fix, with dict) | 99 | 330 s | 2,797,842 | cov 447 | no crash; one "slow unit" (54 s) that replays in <70 ms. It was a load stall, not a hang |
| **New** EditorFuzzer (bytes → ≤400 editor ops + stitch, effect, pixelRect) | 777 | 331 s (first) | 773,886 | cov 1084 | trap: "undo-all did not restore initial state" (see below) |
| EditorFuzzer (harness fixed) | 777 | 331 s | 265,194 | cov 1076 | no crash |

**Editor fuzzer trap triage:** this was a harness bug, not an app bug. The undo-all invariant was skipped only when the history was full *at the end*. When the 200-step limit had trimmed the oldest states earlier, later undos lowered the count again, and the check then (wrongly) expected the full initial state. The fix sets a flag at any point where the history reaches its limit. No ASan reports.

Build: `swiftc -sanitize=fuzzer,address -parse-as-library -O Fuzz/EditorFuzzer.swift Packages/ShareXCore/Sources/ShareXCore/*.swift -o editor-fuzzer`

### Bugs fixed this round (from review and the scans; regression tests in `FinalReviewRegressionTests.swift`)
1. Settings are sanitized on load. Int.max borderWidth → trap in decorate.
2. Tolerant per-key decoding of capture options and tool styles, so an upgrade no longer resets them.
3. Unique save names, so two captures in the same second don't overwrite each other.
