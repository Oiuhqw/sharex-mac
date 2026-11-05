# ShareX for macOS source security audit

The goal is a lightweight native screenshot app with precise selection, editing, clipboard and local output, and configurable shortcuts. This standard-profile audit reviewed the whole source repository at `e8f95968852fc85900f98e6f966d348935f35192`. Documentation was modified in the worktree; application, package, script and workflow sources matched that commit.

The audit found no candidate that met the required principal, boundary and meaningful-result criteria. All 47 planned source units have evidence. Two independent coverage critics accepted the completed coverage without additional work. This result does not prove that the app has no vulnerabilities, and it is not a completed full fuzz campaign.

## Scope and method

Scope covered production capture, settings, shortcuts, native interfaces, image allocation, redaction, caches, editor lifetime, export, clipboard, file recovery, developer helpers, dependency inputs, CI and packaging. The pinned KeyboardShortcuts 3.1.0 source at revision `772133d9dbe800fdac0473226822994c5c162c58` was included. Generated build output, Git internals and other `.audit` contents were excluded. No live deployment, repository access policy, installed app or external service was assessed.

The execution policy was `sandboxed-source-and-local-only`. Actual audit work was source-only. The Windows host could not enforce every required OS sandbox control, and WSL was prohibited. Hunters and critics did not run target code, tests, fixtures, fuzzers, builds, network requests or CI. No runtime artifact was promoted. Every ledger check has `method: source` and `artifact: null`. Ordinary native product CI was a separate verification activity.

No compatible prior coverage ledger or findings file was available. No prior confirmation was carried, and no prior fingerprint was excluded. No agent budget was set. The source plan used four reconnaissance agents, seven hunters and two coverage critics. Two candidate-verifier calls were reserved but unnecessary because no candidate survived. Six additional agents reviewed the Windows validator constraint and its transport. Actual audit spend was 19 agent invocations, comprising 13 source-review and six validator-support calls. Separate product implementation/review agents are not included.

The five selected companion domains were desktop/local IPC, memory/binary safety, resource exhaustion, supply chain/release, and data isolation/lifecycle. Web, cloud, model, tenant and broker boundaries were not invented where source provided no corresponding entry point.

Both unchanged report validators ran on Linux against encrypted copies of the exact parent-authored JSON files. Original tool hashes and report hashes were checked at final checkpoint 11 in [validation run 42023926602](https://github.com/Oiuhqw/sharex-mac/actions/runs/42023926602). The ledger SHA-256 is `dcf6f02d7868aed7c558ba53f98c5a44bca276b7ce14eca4aec7b62cb79bd8ea`; the findings SHA-256 is `37517e5f3dc66819f61f5a7bb8ace1921282415f10551d2defa5c3eb0985b570`. Their success establishes report structure and coverage consistency, not application security. See [the ledger](coverage-ledger.json), [structured findings](findings.json), and [architecture](architecture.md).

## Confirmed findings

| Severity | Title | Affected boundary | Observed result |
| --- | --- | --- | --- |
| Not applicable | None | None | No qualifying candidate was produced. |

There are zero confirmed, zero rejected and zero needs-validation records. Phase 3 had no candidate to verify. Phase 5 had no retained record requiring a final verifier. Neither stage was used to waive a candidate or lower its evidence requirement. [Finding detail](FINDINGS-DETAIL.md) contains no reproduction claim.

## Needs validation

| Lead | Source trace | Blocker | Local next step | Owner observation |
| --- | --- | --- | --- | --- |
| None qualified | Not applicable | Not applicable | Not applicable | Not applicable |

Missing runtime or deployment facts alone were not converted into vulnerability leads. [Validation limits](NEEDS-VALIDATION.md) distinguish those limits from findings.

## Hardening and correctness notes

The hunters recorded 17 notes covering 16 topics. Two agents independently noted the same Last Region behavior. These are not confirmed vulnerabilities and have no severity assignment.

| Area | Source observation and narrow improvement |
| --- | --- |
| Last Region | `Settings.swift` falls back to the first display when the saved ID is absent. `CaptureCoordinator.swift` describes a Region fallback. Require the saved display or request a new selection to prevent unintended output with the editor disabled. |
| Stored shortcut size | The dependency parses separate shortcut preference strings without a byte cap. Bound owned shortcut values before JSON decoding. |
| Stored shortcut integers | Synthesized shortcut decoding bypasses native integer-width validation. Reject values that cannot fit registration and display conversions before use. The source establishes preference-corruption self-impact, not privilege gain. |
| Large editor documents | Marks, text and freehand points have no total document budget. Long local sessions can increase memory and repeated path work despite bounded image caches. Consider a measured document budget or point simplification. |
| Error logging | `Export.swift` makes direct paths private but logs localized error descriptions publicly. Keep descriptive text private and publish stable error codes. No unauthorized reader or secret disclosure was established. |
| Directory replacement | Automatic saving checks a directory, then writes by path. Descriptor-relative creation could protect a shared directory whose parents another principal can rename. No such ACL arrangement or unauthorized result was established. |
| Filename collisions | `uniqueFileName` has an uncapped suffix lookup before bounded write retries. A finite scan with an exclusive alternate candidate would bound local lookup work. |
| Package artifact order | The DMG upload precedes the installation probe. Upload after all package checks, or clearly label artifacts from failed runs. No automatic failed-run artifact consumer was found. |
| Publisher identity | The package is explicitly ad-hoc signed and not notarized. A neighboring checksum detects corruption but does not authenticate a publisher. Authenticated distribution requires a trusted release record or Developer ID signing and notarization. |
| Generator temporary files | CI setup uses fixed `/tmp` paths for its hash-verified generator. A private temporary directory would reduce local substitution opportunities. No lower-trust runner writer was established. |
| Reusable runner selection | Manual dispatch restricts runner choices, while the reusable workflow accepts a string. Apply the same allowlist if caller or runner-fleet authority expands. |
| Developer diagnostic inputs | Test-only JSON/image diagnostics include whole-file reads and decoding before size checks. Bound those inputs if the tools will process files from less-trusted sources. |
| AX intermediate data | The helper bounds visits, deadlines and encoded replies, but AX arrays and strings can be materialized earlier. Bound intermediate collections for stronger test-process resource control. |
| Developer process cleanup | The timeout wrapper should reject non-finite values and can improve interruption/descendant cleanup. Its existing direct-child timeout is not an OS sandbox. |
| Test-script SQL values | Checkout-derived paths are interpolated into TCC SQL. Quote or bind those values to support paths containing apostrophes. The invoking operator already holds runner authority. |
| Secret-file ignores | No committed secret was found. Add relevant secret-file patterns if such files enter the developer workflow; an ignore rule is not a credential boundary. |

Follow-up changes must be reviewed and tested separately. This report keeps the audited source revision fixed instead of implying that later code was part of this pass.

## Positive source patterns

- Production exposes native user actions rather than a network listener, document importer or runtime plugin loader. Capture enters the native Screen Recording gate.
- Image admission checks dimensions, arithmetic and actual row storage. Committed and live effect caches have explicit byte limits.
- Later effects receive masked input beneath earlier protections. Export uses the final flattened image, and editor closure releases application-held preview resources.
- Automatic file writes use non-overwriting creation. Clipboard and file results remain independent during recovery, and successful destinations are not repeated.
- Build inputs have exact package/action pins and a generator digest. Production excludes the E2E driver; the test helper binds operations to its parent and checks foreground ownership before posting pointer events.

## Coverage and limits

| Measure | Result |
| --- | ---: |
| Covered source units | 47 |
| Owned source checks | 85 |
| Distinct reviewed source paths | 88 |
| Candidate units | 0 |
| Blocked units | 0 |
| Deferred units | 0 |
| Planned or in-progress units | 0 |
| Out-of-scope source units discovered | 0 |
| Immediate post-wave critic | Clean |
| Distinct final-clean critic | Clean |

The directory and execution exclusions above remain explicit limits. A source review cannot establish native TCC behavior, installed signing identity, hostile filesystem arrangements, physical keyboard behavior, real mixed-display/Retina operation, framework internals, long-session memory bounds, or current advisory database completeness. Zero deferred source units does not mean those external facts were tested.

The earlier full fuzzing attempt was rejected by automatic safety review for possible cybersecurity risk before it produced results. It was stopped and was not rerouted. Existing seeded property tests and AddressSanitizer checks in ordinary CI are narrower product checks and must not be described as that full campaign.
