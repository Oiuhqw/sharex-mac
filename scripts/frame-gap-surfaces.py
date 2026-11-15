#!/usr/bin/env python3
"""Collect four original full-workflow cycles in fixed original/owned/owned/original order."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("surface_workload", ROOT / "frame-gap-workload.py")
WORKLOAD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WORKLOAD)
GAP = WORKLOAD.GAP
APP = Path("/Applications/ShareX.app")
ORDER = ("original", "owned", "owned", "original")
PHASES = (("setup", "e2e-agent-setup.py", 480), ("native", "e2e-agent-capture.py", 1080),
          ("clients", "e2e-agent-clients.py", 720), ("maintenance", "e2e-desktop-maintenance.py", 900))
BUDGET_SECONDS = 34 * 60


def bundle_files(directory):
    if not directory.is_dir() or directory.is_symlink():
        raise RuntimeError(f"Expected a real app bundle: {directory}")
    return {str(path.relative_to(directory)): {"link": os.readlink(path)} if path.is_symlink()
            else {"sha256": WORKLOAD.digest(path)}
            for path in sorted(directory.rglob("*")) if path.is_symlink() or path.is_file()}


def command(arguments, log_path, environment, deadline, timeout=120):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise RuntimeError("Comparison reached its 34-minute collection budget.")
    result = WORKLOAD.bounded_harness(arguments, log_path, environment, min(timeout, remaining))
    if result["exitCode"] != 0 or result["timedOut"]:
        raise RuntimeError(f"Prerequisite command failed: {arguments[0]}. See {log_path}.")


def prepare_cycle(args, directory, cycle, expected_bundle, environment, deadline):
    if bundle_files(args.built_app) != expected_bundle:
        raise RuntimeError("The signed build bundle changed during comparison.")
    if cycle > 1:
        if args.app.exists() or args.app.is_symlink():
            raise RuntimeError("Prior maintenance left an installed app. No replacement or deletion is allowed.")
        command(["/usr/bin/ditto", args.built_app, args.app], directory / "restore.log", environment, deadline)
    if bundle_files(args.app) != expected_bundle:
        raise RuntimeError("Installed app differs from the exact signed build bundle.")
    command(["/usr/bin/codesign", "--verify", "--deep", "--strict", args.app],
            directory / "signature.log", environment, deadline)
    if cycle > 1:
        command(["/bin/bash", ROOT / "ci-capture-permissions.sh", args.app],
                directory / "permissions.log", environment, deadline)
        command(["/usr/bin/defaults", "write", "com.sharexmac.ShareX", "agentCaptureEnabled", "-bool", "false"],
                directory / "disabled.log", environment, deadline)


def treatment_evidence(trace_directory, arm):
    copies, appended, heartbeats = 0, 0, 0
    errors = []
    traces = sorted(trace_directory.glob("*-trace.json"))
    if not traces:
        errors.append("No recorder traces were retained.")
    for path in traces:
        trace = GAP.read_json(path)
        beats = trace.get("heartbeats", [])
        heartbeats += len(beats)
        if not beats:
            errors.append(f"No heartbeat events in {path.name}.")
        for callback in trace.get("callbacks", []):
            if callback.get("ownedBuffers") is not (arm == "owned"):
                errors.append(f"Wrong or missing buffer mode in {path.name}.")
                break
            if arm == "original" and any(key.startswith("copy") or key.startswith("ownedBase")
                                          or key == "ownedSurfaceID" for key in callback):
                errors.append(f"Original arm contains copy evidence in {path.name}.")
                break
            if callback.get("copySucceeded"):
                copies += 1
            if arm == "owned" and callback.get("copySucceeded") is False:
                errors.append(f"Owned-buffer copy failed in {path.name}.")
            if callback.get("appended") is not True:
                continue
            appended += 1
            if arm == "owned":
                source, owned = callback.get("sourceBaseAddress"), callback.get("ownedBaseAddress")
                source_surface, owned_surface = callback.get("surfaceID"), callback.get("ownedSurfaceID")
                if not (callback.get("copySucceeded") is True and callback.get("copyDisjoint") is True
                        and isinstance(source, int) and isinstance(owned, int) and source != owned
                        and callback.get("copyEnd", -1) >= callback.get("copyStart", 0)
                        and callback.get("copyBytes", 0) > 0
                        and callback["copyBytes"] == callback.get("copyWidth", 0) * callback.get("copyHeight", 0) * 4
                        and (source_surface is None or owned_surface is None or source_surface != owned_surface)):
                    errors.append(f"Appended frame lacks a proven disjoint copy in {path.name}.")
                    break
    if not appended:
        errors.append("No appended frames prove the selected buffer mode.")
    return {"appendedFrames": appended, "successfulCopies": copies, "heartbeatEvents": heartbeats,
            "errors": errors}


def analyze_phase(record, evidence, traces, arm):
    errors = record.setdefault("infrastructureErrors", [])
    record["qualityFailures"] = []
    try:
        result = GAP.read_json(evidence / "result.json")
        record["originalResult"] = result
        expected_exit = {"passed": 0, "failed": 1, "blocked": 3}.get((result or {}).get("status"))
        if expected_exit is None or record.get("exitCode") != expected_exit or record.get("timedOut"):
            errors.append("Harness result is missing or inconsistent with its process exit.")
        if (result or {}).get("status") == "blocked":
            errors.append("Original harness reported blocked.")
        events = evidence / "events.jsonl"
        if events.exists():
            for line in events.read_text(encoding="utf-8").splitlines():
                event = json.loads(line)
                if event.get("event") == "media_decoded" and event.get("verification", {}).get("status") == "failed":
                    record["qualityFailures"].append(event)
        if traces is not None:
            retained = WORKLOAD.retained_evidence(evidence, traces)
            record["retainedEvidence"] = retained
            record["treatmentEvidence"] = treatment_evidence(traces, arm)
            errors.extend(record["treatmentEvidence"]["errors"])
            if not retained["fixtureDrawCount"] or not retained["fixtureOperationCount"]:
                errors.append("Fixture traces are missing or empty.")
            if any(value != 0 for value in retained["fixtureOverflow"].values()):
                errors.append("Fixture trace is missing or overflowed.")
            if retained["unmatchedTraces"] or any(not WORKLOAD.abrupt_exit_recovery(row) for row in retained["missingTraces"]):
                errors.append("Recorder trace coverage is incomplete.")
            if any(row["operationOverflow"] or row["analysis"].get("traceOverflow") for row in retained["traces"]):
                errors.append("Recorder trace overflowed.")
    except (OSError, ValueError, TypeError, KeyError) as error:
        errors.append(f"Evidence analysis failed: {error}")
    record["harnessFailed"] = (record.get("originalResult") or {}).get("status") != "passed"
    steps = (record.get("originalResult") or {}).get("steps", [])
    record["observedSteps"] = len(steps)
    record["endedAfterStep"] = steps[-1].get("name") if steps else None


def run_phase(args, directory, arm, phase, script, timeout, environment, deadline):
    evidence = directory / phase
    traces = None
    phase_environment = dict(environment)
    if phase in ("native", "clients"):
        traces = directory / f"{phase}-traces"
        traces.mkdir()
        phase_environment.update(SHAREX_FRAME_GAP_WORKLOAD="1", SHAREX_FRAME_GAP_FIXTURE_TRACE="1",
                                 SHAREX_FRAME_GAP_TRACE_DIR=str(traces), SHAREX_FRAME_GAP_HEARTBEAT="1",
                                 SHAREX_FRAME_GAP_OWNED_BUFFERS=str(int(arm == "owned")))
    arguments = [sys.executable, ROOT / script, "--app", args.app, "--build-settings", args.build_settings, "--out", evidence]
    arguments += ["--codex", args.codex, "--claude", args.claude] if phase == "clients" else (
        ["--helper", args.helper] if phase in ("setup", "maintenance") else [])
    record = {"phase": phase, "arm": arm, "evidence": str(evidence), "timeoutSeconds": timeout,
              "infrastructureErrors": []}
    try:
        if phase in ("native", "clients"):
            command(["/usr/bin/defaults", "write", "com.sharexmac.ShareX", "agentCaptureEnabled", "-bool", "true"],
                    directory / f"{phase}-enabled.log", phase_environment, deadline)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("Comparison reached its 34-minute collection budget.")
        record.update(WORKLOAD.bounded_harness(arguments, directory / f"{phase}.log", phase_environment,
                                              min(timeout, remaining)))
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        record["infrastructureErrors"].append(str(error))
    analyze_phase(record, evidence, traces, arm)
    return record


def run(args):
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_OS") != "macOS":
        raise RuntimeError("Surface comparison requires a disposable GitHub macOS runner.")
    if args.app.resolve() != APP or args.app.is_symlink():
        raise RuntimeError("Surface comparison requires the dedicated /Applications/ShareX.app installation.")
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=False)
    environment = {key: value for key, value in os.environ.items() if not key.startswith("SHAREX_FRAME_GAP_")}
    deadline = time.monotonic() + BUDGET_SECONDS
    summary = {"diagnosticOnly": True, "commit": args.commit, "order": ORDER, "heartbeat": True,
               "status": "incomplete", "cycles": [], "infrastructureErrors": [], "timeBudgetSeconds": BUDGET_SECONDS,
               "interpretation": "Collected means evidence collection completed, not that E2E passed or the gap is fixed. "
               "Copying also adds CPU work. A difference alone does not prove buffer-pool exhaustion. "
               "All original assertions and verifier bounds remain in force; no failed capture is retried. "
               "A failed original harness can leave later cases unrun. Its exact step records remain in originalResult. "
               "Session storage accumulates across cycles; fixed ABBA order counterbalances, but does not remove, state drift."}
    GAP.save(output / "comparison.json", summary)
    try:
        expected_bundle = bundle_files(args.built_app)
        summary["signedBundleFiles"] = expected_bundle
        for cycle, arm in enumerate(ORDER, 1):
            directory = output / f"cycle-{cycle:02d}-{arm}"
            directory.mkdir()
            record = {"cycle": cycle, "arm": arm, "phases": []}
            summary["cycles"].append(record)
            prepare_cycle(args, directory, cycle, expected_bundle, environment, deadline)
            for phase, script, timeout in PHASES:
                record["phases"].append(run_phase(args, directory, arm, phase, script, timeout, environment, deadline))
                GAP.save(output / "comparison.json", summary)
                latest = record["phases"][-1]
                print(json.dumps({"event": "phase_finished", "cycle": cycle, "arm": arm, "phase": phase,
                                  "harnessStatus": (latest.get("originalResult") or {}).get("status", "missing"),
                                  "qualityFailures": len(latest["qualityFailures"]),
                                  "infrastructureErrors": latest["infrastructureErrors"]}), flush=True)
            if args.app.exists() or args.app.is_symlink():
                raise RuntimeError(f"Cycle {cycle} maintenance left an installed app. Comparison stopped without replacing it.")
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        summary["infrastructureErrors"].append(str(error))
    phases = [phase for cycle in summary["cycles"] for phase in cycle["phases"]]
    summary["harnessFailures"] = sum(phase["harnessFailed"] for phase in phases)
    summary["qualityFailures"] = sum(len(phase["qualityFailures"]) for phase in phases)
    summary["qualityFailureCountBasis"] = "Failed original media-verifier invocations. Later cases may be unrun after a harness failure."
    summary["otherHarnessFailures"] = sum(phase["harnessFailed"] and not phase["qualityFailures"] for phase in phases)
    summary["infrastructureFailures"] = len(summary["infrastructureErrors"]) + sum(bool(phase["infrastructureErrors"]) for phase in phases)
    summary["arms"] = {}
    for arm in ("original", "owned"):
        captures = [phase for phase in phases if phase["arm"] == arm and phase["phase"] in ("native", "clients")]
        summary["arms"][arm] = {"nativeClientRuns": len(captures),
                                "qualityFailures": sum(len(phase["qualityFailures"]) for phase in captures),
                                "harnessFailures": sum(phase["harnessFailed"] for phase in captures),
                                "infrastructureFailures": sum(bool(phase["infrastructureErrors"]) for phase in captures)}
        for field in ("appendedFrames", "successfulCopies", "heartbeatEvents"):
            summary["arms"][arm][field] = sum(phase.get("treatmentEvidence", {}).get(field, 0) for phase in captures)
    summary["harnessStatus"] = "passed" if len(phases) == 16 and not summary["harnessFailures"] else "failed"
    summary["status"] = "collected" if len(phases) == 16 and not summary["infrastructureFailures"] else "incomplete"
    GAP.save(output / "comparison.json", summary)
    print(json.dumps({key: value for key, value in summary.items() if key not in ("cycles", "signedBundleFiles")}, indent=2))
    return 0 if summary["status"] == "collected" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("app", "built-app", "build-settings", "helper", "codex", "claude", "out"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--commit", required=True)
    try:
        sys.exit(run(parser.parse_args()))
    except Exception as error:
        print(f"Surface comparison incomplete: {error}", file=sys.stderr)
        sys.exit(1)
