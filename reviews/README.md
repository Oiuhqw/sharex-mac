# Review evidence

The current implementation assessment is [Security, resource use, and settings review](security-lightweight-0.1.2.md). Read its revision and validation status before using any result as a release decision.

The [completed source security audit](security-audit-2026-11-05/REPORT.md) covers revision `e8f9596`. It records 47 covered units, 85 source checks, and no confirmed vulnerability. It includes the exact coverage ledger and validation limits. The [post-audit source review](security-audit-2026-11-05/FOLLOW-UP.md) checks later production fixes at `acfa92f`. Native results remain separate in the implementation assessment.

Other reports in this directory describe earlier revisions and review rounds. Their pass counts, performance numbers, fuzz results, and sign-off statements are historical. They do not establish that the current revision passes. In particular, an old fuzz report is not evidence that the current full fuzz campaign completed.

The current workflow is documented in [README.md](../README.md), [the product brief](../BRIEF.md), and [the implementation plan](../PLAN.md).

The [decision trail](decision-trail.tsv) preserves the recorded work and evidence. Two historical rows lacked a reason field; the public copy inserts an empty field in each row without changing their text or timestamps.
