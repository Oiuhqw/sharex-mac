#!/usr/bin/env python3
"""Re-report selected sample ranges from a completed system profile."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import sys
import time


SPEC = importlib.util.spec_from_file_location("profiler_capability", Path(__file__).with_name("profiler-capability.py"))
capability = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(capability)
preflight = capability.preflight
COMMAND_SECONDS = 12
MANUAL_CLAUSES = (
    "-i path Read in the file located at path rather than sampling the live system.",
    "-indexRange s-e Only include samples in the given range",
)


def sample_ranges(report_bytes, requested=None):
    match = re.search(rb"(?m)^Steps:[ \t]+([0-9]+)[ \t]+\(", report_bytes)
    if match is None or int(match[1]) < 3:
        raise ValueError("The capability report requires a Steps header with at least three samples")
    steps = int(match[1])
    ranges = {"first": (1, 1), "middle": ((steps + 1) // 2, (steps + 1) // 2), "last": (steps, steps)}
    if requested is not None:
        ranges = {}
        for value in requested:
            if re.fullmatch(r"[0-9]+-[0-9]+", value) is None:
                raise ValueError("Each index range must use the form START-END with ASCII integers")
            start, end = map(int, value.split("-"))
            if not 1 <= start <= end <= steps:
                raise ValueError(f"Index range {value} must satisfy 1 <= start <= end <= {steps}")
            ranges[f"samples-{start}-{end}"] = (start, end)
        if not ranges:
            raise ValueError("At least one index range is required")
    return steps, ranges


def collect_probe(out, commit, documentation, source, cancellation, source_profile=False,
                  index_ranges=None, tooling_commit=None):
    out.mkdir(parents=True, exist_ok=False)
    report = {"schemaVersion": 1, "phase": "profiler_clock_probe", "commit": commit,
              "started": preflight.clock(), "outcome": "incomplete", "commands": [],
              "perCommandLimitSeconds": COMMAND_SECONDS, "productionE2EPassed": False,
              "clockMappingValidated": False, "validationPending": "Inspect selected report headers for sample timestamps"}
    if tooling_commit is not None:
        report["toolingCommit"] = tooling_commit
    manifest = out / "clock-probe.json"
    preflight.write_json(manifest, report)
    try:
        cancellation.check()
        report["documentation"] = capability.validate_documentation(documentation, commit)
        manual = " ".join((documentation / "spindump-manual.plain.txt").read_text(encoding="utf-8").split())
        if any(clause not in manual for clause in MANUAL_CLAUSES):
            raise ValueError("Installed spindump manual does not confirm input and index-range options")
        report["documentation"]["confirmedClauses"].extend(MANUAL_CLAUSES)
        collection = json.loads((source / ("source-profile.json" if source_profile else "capability.json")).read_text(encoding="utf-8"))
        if collection["commit"] != commit or collection["outcome"] != "collection_complete":
            raise ValueError("The matching commit requires a completed capability collection")
        source_report = (source / "report" / "system.spindump.txt").resolve()
        content = source_report.read_bytes()
        steps, ranges = sample_ranges(content, index_ranges)
        report["source"] = {"path": str(source_report), "sha256": hashlib.sha256(content).hexdigest(),
                            "sizeBytes": len(content), "steps": steps}
        report["ranges"] = ranges
        for name, (start, end) in ranges.items():
            cancellation.check()
            argv = ("/usr/sbin/spindump", "-i", str(source_report), "-indexRange", f"{start}-{end}",
                    "-timeline", "-displayIdleWorkQueueThreads", "-timelimit", "8",
                    "-o", str(out / f"{name}.spindump.txt"))
            deadline = time.monotonic() + COMMAND_SECONDS
            child = capability.OwnedChild(name, argv, out)
            try:
                child.wait(deadline - 2, cancellation)
            finally:
                child.close(deadline)
                report["commands"].append(child.record)
                preflight.write_json(manifest, report)
            cancellation.check()
            if child.record["status"] != "completed" or not child.record["cleanupComplete"]:
                raise RuntimeError(f"The {name} re-report command failed or did not clean up")
        report["outcome"] = "commands_complete"
    except (OSError, ValueError, RuntimeError, KeyError, InterruptedError, KeyboardInterrupt) as error:
        report["error"] = {"type": type(error).__name__, "message": str(error)}
    finally:
        try:
            out.chmod(0o755)
            for path in out.iterdir():
                path.chmod(0o644)
        except OSError as error:
            report["error"] = {"type": type(error).__name__, "message": str(error)}
        if cancellation.error is not None:
            report["error"] = {"type": type(cancellation.error).__name__, "message": str(cancellation.error)}
        if "error" in report:
            report["outcome"] = "incomplete"
        report["finished"] = preflight.clock()
        preflight.write_json(manifest, report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--preflight", type=Path, required=True)
    parser.add_argument("--capability", type=Path, required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--tooling-commit", help="Commit of the code that re-reports the retained capture")
    parser.add_argument("--source-profile", action="store_true", help="Read a completed 12-second source profile collection")
    parser.add_argument("--index-range", action="append", metavar="START-END",
                        help="Inclusive one-based sample range; repeat to replace the default first, middle, and last")
    args = parser.parse_args()
    if args.out.exists():
        parser.error("--out must be a new directory to preserve earlier evidence")
    if sys.platform != "darwin" or os.geteuid() != 0:
        parser.error("Run this Mac-only re-report probe explicitly through noninteractive sudo")
    cancellation = capability.Cancellation()
    signal.signal(signal.SIGTERM, cancellation.request)
    signal.signal(signal.SIGINT, cancellation.request)
    report = collect_probe(args.out, args.commit, args.preflight, args.capability, cancellation,
                           source_profile=args.source_profile, index_ranges=args.index_range,
                           tooling_commit=args.tooling_commit)
    print(f"{report['outcome']}: {args.out / 'clock-probe.json'}; clock mapping validation remains pending")
    return 0 if report["outcome"] == "commands_complete" else 1


if __name__ == "__main__":
    sys.exit(main())
