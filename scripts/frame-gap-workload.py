#!/usr/bin/env python3
"""Run three diagnostic native/client cycles without stopping at the first failure."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("frame_gap_probe", ROOT / "frame-gap-probe.py")
GAP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GAP)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def current_binary_hash(path):
    return digest(path) if path.is_file() else None


def abrupt_exit_recovery(session):
    return session.get("state") == "interrupted" and session.get("stopReason") == "app_restart"


def bounded_harness(arguments, log_path, environment, timeout):
    started = time.monotonic()
    with log_path.open("wb") as log:
        process = subprocess.Popen([str(value) for value in arguments], stdout=log, stderr=subprocess.STDOUT,
                                   env=environment, start_new_session=True)
        timed_out = False
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            process.terminate()
            try:
                process.wait(timeout=45)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
    return {"exitCode": process.returncode, "timedOut": timed_out,
            "startMonotonicSeconds": started, "endMonotonicSeconds": time.monotonic(), "pid": process.pid}


def retained_evidence(evidence, trace_directory):
    draws = GAP.read_json(evidence / "fixture/draw-trace.json") or []
    fixture_operations = GAP.read_json(evidence / "fixture/operation-trace.json") or []
    trace_records = []
    traced_sessions = set()
    for path in sorted(trace_directory.glob("*-trace.json")):
        trace = GAP.read_json(path)
        context = trace.get("context") or {}
        session_id = Path(context.get("videoPath", "")).parent.name.upper()
        if session_id:
            traced_sessions.add(session_id)
        trace_records.append({"path": str(path), "sessionID": session_id, "context": context,
                              "analysis": GAP.summarize({"trace": trace}, draws),
                              "operationCount": len(trace.get("operations", [])),
                              "operationOverflow": trace.get("operationOverflow", 0)})
    sessions = {}
    for path in sorted((evidence / "session-snapshots").glob("*/manifest.json")):
        manifest = GAP.read_json(path)
        if any(item.get("kind") == "recording" for item in manifest.get("artifacts", [])):
            session_id = manifest["id"].upper()
            files = [{"path": str(video), "bytes": video.stat().st_size, "sha256": digest(video)}
                     for video in path.parent.rglob("*.mp4")]
            sessions[session_id] = {"state": manifest.get("state"), "stopReason": manifest.get("stopReason"),
                                    "tracePresent": session_id in traced_sessions, "retainedVideos": files}
    missing = [{"sessionID": key, **value} for key, value in sessions.items() if not value["tracePresent"]]
    fixture_overflow = {}
    for name in ("draw-trace-overflow.txt", "operation-trace-overflow.txt"):
        path = evidence / "fixture" / name
        fixture_overflow[name] = int(path.read_text().strip()) if path.exists() else None
    return {"traces": trace_records, "recordingSessions": sessions, "missingTraces": missing,
            "fixtureDrawCount": len(draws), "fixtureOperationCount": len(fixture_operations), "fixtureOverflow": fixture_overflow,
            "traceCoverageNote": "Abrupt process exit can prevent a final trace flush. Missing traces are listed; "
                                 "they are not evidence of continuous capture. Fixture drawing does not prove compositor presentation."}


def run(args):
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("Workload diagnostics require a disposable GitHub macOS runner.")
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=False)
    binary = args.app.resolve() / "Contents/MacOS/ShareX"
    initial_hash = digest(binary)
    clock = time.get_clock_info("monotonic")
    summary = {"diagnosticOnly": True, "commit": args.commit, "installedBinary": str(binary),
               "installedBinarySHA256": initial_hash, "fixedCycles": 3, "runs": [],
               "monotonicClock": {key: getattr(clock, key) for key in ("implementation", "monotonic", "adjustable", "resolution")},
               "scope": "Three native CLI/MCP and real Codex/Claude client cycles on one runner. "
                        "Original assertions and 0.5-second animated-media bound remain in force. "
                        "Setup and maintenance are excluded from this diagnostic workload."}
    GAP.save(output / "workload.json", summary)
    for cycle in range(1, 4):
        cycle_directory = output / f"cycle-{cycle:02d}"
        cycle_directory.mkdir()
        for kind, timeout in (("native", 420), ("clients", 300)):
            evidence = cycle_directory / kind
            trace_directory = cycle_directory / f"{kind}-traces"
            trace_directory.mkdir()
            environment = {**os.environ, "SHAREX_FRAME_GAP_WORKLOAD": "1", "SHAREX_FRAME_GAP_FIXTURE_TRACE": "1",
                           "SHAREX_FRAME_GAP_TRACE_DIR": str(trace_directory)}
            script = "e2e-agent-capture.py" if kind == "native" else "e2e-agent-clients.py"
            arguments = [sys.executable, ROOT / script, "--app", args.app, "--build-settings", args.build_settings,
                         "--out", evidence]
            if kind == "clients":
                arguments += ["--codex", args.codex, "--claude", args.claude]
            record = {"cycle": cycle, "kind": kind, "evidence": str(evidence), "traceDirectory": str(trace_directory),
                      "timeoutSeconds": timeout, "binaryHashBefore": current_binary_hash(binary)}
            try:
                record.update(bounded_harness(arguments, cycle_directory / f"{kind}.log", environment, timeout))
            except (OSError, subprocess.TimeoutExpired) as error:
                record.update(exitCode=None, executionError=str(error))
            record["binaryHashAfter"] = current_binary_hash(binary)
            record["binaryUnchanged"] = record["binaryHashBefore"] == record["binaryHashAfter"] == initial_hash
            try:
                record["result"] = GAP.read_json(evidence / "result.json")
                record["retainedEvidence"] = retained_evidence(evidence, trace_directory)
            except (OSError, ValueError, TypeError, KeyError) as error:
                record["evidenceAnalysisError"] = str(error)
            summary["runs"].append(record)
            GAP.save(output / "workload.json", summary)
            print(f"Cycle {cycle}/3 {kind}: exit={record.get('exitCode')}, binaryUnchanged={record['binaryUnchanged']}", flush=True)
    summary["failedHarnessRuns"] = sum(item.get("exitCode") != 0 for item in summary["runs"])
    summary["binaryChanges"] = sum(not item["binaryUnchanged"] for item in summary["runs"])
    summary["missingTraceCount"] = sum(len(item.get("retainedEvidence", {}).get("missingTraces", [])) for item in summary["runs"])
    summary["abruptExitMissingTraceCount"] = sum(abrupt_exit_recovery(missing) for item in summary["runs"]
                                               for missing in item.get("retainedEvidence", {}).get("missingTraces", []))
    summary["diagnosticEvidenceFailures"] = sum(
        bool(item.get("evidenceAnalysisError")) or item.get("result") is None
        or not item.get("retainedEvidence", {}).get("fixtureDrawCount")
        or not item.get("retainedEvidence", {}).get("fixtureOperationCount")
        or any(value != 0 for value in item.get("retainedEvidence", {}).get("fixtureOverflow", {}).values())
        or any(not abrupt_exit_recovery(missing) for missing in item.get("retainedEvidence", {}).get("missingTraces", []))
        or any(trace.get("operationOverflow") or trace["analysis"].get("traceOverflow")
               for trace in item.get("retainedEvidence", {}).get("traces", []))
        for item in summary["runs"])
    summary["harnessStatus"] = "passed" if summary["failedHarnessRuns"] == 0 else "failed"
    summary["diagnosticStatus"] = "complete" if not (summary["diagnosticEvidenceFailures"] or summary["binaryChanges"]) else "incomplete"
    summary["status"] = "passed" if not (summary["failedHarnessRuns"] or summary["binaryChanges"] or summary["diagnosticEvidenceFailures"]) else "failed"
    GAP.save(output / "workload.json", summary)
    print(json.dumps({key: value for key, value in summary.items() if key != "runs"}, indent=2, sort_keys=True))
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--build-settings", type=Path, required=True)
    parser.add_argument("--codex", type=Path, required=True)
    parser.add_argument("--claude", type=Path, required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--out", type=Path, required=True)
    try:
        sys.exit(run(parser.parse_args()))
    except Exception as error:
        print(f"Frame gap workload incomplete: {error}", file=sys.stderr)
        sys.exit(1)
