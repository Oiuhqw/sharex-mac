# Review evidence

The current implementation assessment is [Multi-display capture and release validation for 0.1.3](multidisplay-0.1.3.md). It records the diagnostic source, native check counts, virtual-display inputs, actual editor-window images, resource gates, and package checks. The app supports Apple Silicon on macOS 14 or later. Intel Macs are unsupported.

The final PR records independent review and native validation at its exact documentation head. The [0.1.3 release](https://github.com/Oiuhqw/sharex-mac/releases/tag/v0.1.3) identifies the merged-main package build and provides its checksum. These identities are separate from the diagnostic run because the DMG includes `INSTALL.txt`.

Automated mixed-scale coverage uses deterministic frozen tiles on real 1x and 2x `NSScreen` geometry. ScreenCaptureKit captures the actual editor windows for native comparisons. Physical mouse transitions, separate Spaces, physical hot-plug, real mixed-density display capture, physical shortcuts, and interactive permission prompts remain hardware checks.

## Historical 0.1.2 assessment

[Security, resource use, and settings review](security-lightweight-0.1.2.md) covers the earlier implementation. [PR 3](https://github.com/Oiuhqw/sharex-mac/pull/3) merged as `65a3e36`. Its tree matches the independently reviewed head `4a95733`.

The [historical main run](https://github.com/Oiuhqw/sharex-mac/actions/runs/42038241966) passed 97 core tests, the same 97 under AddressSanitizer, 26 script tests, 420 normal E2E checks, and 63 shortcut-recovery checks. It recorded zero E2E failures and six unverified checks. Universal packaging and six memory ownership checks passed. The earlier checkpoint `a5cb376` also passed its native suite on Intel and Apple Silicon. These results do not extend Intel support to 0.1.3.

That assessment records active memory, timing spikes, and the incomplete full fuzz campaign. The current deterministic property tests and AddressSanitizer runs do not complete that larger campaign.

## Historical security audit

The [completed source security audit](security-audit-2026-11-05/REPORT.md) covers revision `e8f9596`. It records 47 covered units, 85 source checks, and no confirmed vulnerability. Its coverage ledger and validation limits remain part of that report.

The [post-audit source review](security-audit-2026-11-05/FOLLOW-UP.md) checks later production fixes at `acfa92f`. Neither report is a complete security audit of the 0.1.3 patch. Current native results remain separate from those source-audit conclusions.

## Historical cleanup evidence

The 5 November 2026 cleanup removed nine auxiliary worktrees, eight local feature branches, six remote feature branches, and 68 obsolete Actions runs. It retained 23 runs referenced by the handoff or review reports. Those counts describe that cleanup only.

On the development host, `.audit/cleanup-20261105/RECOVERY.txt` maps the archived worktrees and evidence. ZIP archives preserve 9,076 files. `git-history.bundle` preserves the original refs and 39 commit tips. These local recovery files are ignored by Git and are not part of the repository or DMG. Older local worktree paths in handoffs refer to files inside those archives.

## Evidence scope

Other reports in this directory describe earlier revisions and review rounds. Their pass counts, performance numbers, fuzz results, and sign-off statements remain historical. They do not establish that the current revision passes. An old fuzz report is not evidence that the current full fuzz campaign completed.

The [decision trail](decision-trail.tsv) preserves recorded work and evidence. Two historical rows lacked a reason field. The public copy inserts an empty field in each row without changing their text or timestamps.

The current product and workflow are documented in [README.md](../README.md), [the product brief](../BRIEF.md), and [the implementation plan](../PLAN.md).
