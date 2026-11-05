# Review evidence

The current implementation assessment is [Security, resource use, and settings review](security-lightweight-0.1.2.md). [PR 3](https://github.com/Oiuhqw/sharex-mac/pull/3) merged as `65a3e36`. Its tree matches the independently reviewed head `4a95733`.

The [main validation run](https://github.com/Oiuhqw/sharex-mac/actions/runs/42038241966) passed 97 core tests, the same 97 under AddressSanitizer, 26 script tests, 420 normal E2E checks, and 63 shortcut-recovery checks. It recorded zero E2E failures and six unverifiable checks. Universal packaging and six memory ownership checks passed. The earlier implementation checkpoint `a5cb376` passed the native suite on both Intel and Apple Silicon. Read the assessment for exact revisions, active memory, timing spikes, and the incomplete full fuzz campaign.

The 5 November 2026 cleanup removed nine auxiliary worktrees, eight local feature branches, six remote feature branches, and 68 obsolete Actions runs. It retained 23 runs referenced by the handoff or review reports. Both GitHub workflows are disabled at the owner's request. Their definitions remain available for future builds. See [the build instructions](../README.md#build-and-verification) to enable them.

On the development host, `.audit/cleanup-20261105/RECOVERY.txt` maps the archived worktrees and evidence. The ZIP archives preserve 9,076 files. `git-history.bundle` preserves the original refs and 39 commit tips. These local recovery files are ignored by Git and are not part of the public repository or DMG. Older local worktree paths in handoffs refer to files inside these archives.

The [completed source security audit](security-audit-2026-11-05/REPORT.md) covers revision `e8f9596`. It records 47 covered units, 85 source checks, and no confirmed vulnerability. It includes the exact coverage ledger and validation limits. The [post-audit source review](security-audit-2026-11-05/FOLLOW-UP.md) checks later production fixes at `acfa92f`. Native results remain separate in the implementation assessment.

Other reports in this directory describe earlier revisions and review rounds. Their pass counts, performance numbers, fuzz results, and sign-off statements are historical. They do not establish that the current revision passes. In particular, an old fuzz report is not evidence that the current full fuzz campaign completed.

The current workflow is documented in [README.md](../README.md), [the product brief](../BRIEF.md), and [the implementation plan](../PLAN.md).

The [decision trail](decision-trail.tsv) preserves the recorded work and evidence. Two historical rows lacked a reason field; the public copy inserts an empty field in each row without changing their text or timestamps.
