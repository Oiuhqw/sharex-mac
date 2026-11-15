#!/usr/bin/env python3
"""Run three diagnostic native/client cycles without stopping at the first failure."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import signal
import subprocess
import sys
import time
import uuid


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
    sessions = {}
    recording_artifacts = {}
    for path in sorted((evidence / "session-snapshots").glob("*/manifest.json")):
        manifest = GAP.read_json(path)
        session_id = str(uuid.UUID(manifest["id"])).upper()
        if path.parent.name.upper() != session_id:
            raise ValueError("Retained manifest ID differs from its local session folder.")
        recordings = [item for item in manifest.get("artifacts", []) if item.get("kind") == "recording"]
        if not recordings:
            continue
        artifacts = []
        for item in recordings:
            artifact_id = str(uuid.UUID(item["id"])).upper()
            files = [{"path": str(video), "bytes": video.stat().st_size, "sha256": digest(video)}
                     for video in sorted((path.parent / artifact_id).rglob("*.mp4"))]
            artifact = {"artifactID": artifact_id, "state": item.get("state"),
                        "tracePresent": False, "retainedVideos": files}
            artifacts.append(artifact)
            recording_artifacts[(session_id, artifact_id)] = artifact
        sessions[session_id] = {"state": manifest.get("state"), "stopReason": manifest.get("stopReason"),
                               "recordingArtifacts": artifacts,
                               "retainedVideos": [video for item in artifacts for video in item["retainedVideos"]]}
    trace_records = []
    unmatched_traces = []
    for path in sorted(trace_directory.glob("*-trace.json")):
        trace = GAP.read_json(path)
        context = trace.get("context") or {}
        session_id, artifact_id = None, None
        try:
            # Parse identifiers only. A Mac path in downloaded evidence is never a local filesystem target.
            video_path = PurePosixPath(context["videoPath"])
            session_id = str(uuid.UUID(video_path.parent.parent.name)).upper()
            artifact_id = str(uuid.UUID(video_path.parent.name)).upper()
        except (KeyError, ValueError, TypeError):
            pass
        matched = recording_artifacts.get((session_id, artifact_id))
        if matched is not None:
            matched["tracePresent"] = True
        else:
            unmatched_traces.append({"path": str(path), "sessionID": session_id, "artifactID": artifact_id,
                                     "reason": "Trace path does not identify a recording artifact in the retained manifests."})
        trace_records.append({"path": str(path), "sessionID": session_id, "artifactID": artifact_id,
                              "manifestMatched": matched is not None, "context": context,
                              "analysis": GAP.summarize({"trace": trace}, draws),
                              "operationCount": len(trace.get("operations", [])),
                              "operationOverflow": trace.get("operationOverflow", 0)})
    missing = []
    for session_id, session in sessions.items():
        session["tracePresent"] = all(item["tracePresent"] for item in session["recordingArtifacts"])
        for item in session["recordingArtifacts"]:
            if not item["tracePresent"]:
                missing.append({"sessionID": session_id, "artifactID": item["artifactID"],
                                "state": session["state"], "stopReason": session["stopReason"],
                                "retainedVideos": item["retainedVideos"]})
    fixture_overflow = {}
    for name in ("draw-trace-overflow.txt", "operation-trace-overflow.txt"):
        path = evidence / "fixture" / name
        fixture_overflow[name] = int(path.read_text().strip()) if path.exists() else None
    return {"traces": trace_records, "recordingSessions": sessions, "missingTraces": missing,
            "unmatchedTraces": unmatched_traces,
            "fixtureDrawCount": len(draws), "fixtureOperationCount": len(fixture_operations), "fixtureOverflow": fixture_overflow,
            "traceCoverageNote": "Traces join through both session and recording artifact UUIDs. "
                                 "Abrupt process exit can prevent a final trace flush. Missing traces are listed; "
                                 "they are not evidence of continuous capture. Fixture drawing does not prove compositor presentation."}


def analyze_run(output, source, initial_hash):
    cycle, kind = source["cycle"], source["kind"]
    if type(cycle) is not int or cycle not in range(1, 4) or kind not in ("native", "clients"):
        raise ValueError("Workload run must identify cycle 1 through 3 and native or clients.")
    evidence = output / f"cycle-{cycle:02d}" / kind
    trace_directory = evidence.parent / f"{kind}-traces"
    fields = ("cycle", "kind", "timeoutSeconds", "binaryHashBefore", "binaryHashAfter", "exitCode", "timedOut",
              "startMonotonicSeconds", "endMonotonicSeconds", "pid", "executionError")
    record = {key: source[key] for key in fields if key in source}
    record.update(evidence=str(evidence), traceDirectory=str(trace_directory),
                  originalEvidencePath=source.get("originalEvidencePath", source.get("evidence")),
                  originalTraceDirectory=source.get("originalTraceDirectory", source.get("traceDirectory")))
    record["binaryUnchanged"] = bool(initial_hash) and record.get("binaryHashBefore") == record.get("binaryHashAfter") == initial_hash
    try:
        record["result"] = GAP.read_json(evidence / "result.json")
        record["retainedEvidence"] = retained_evidence(evidence, trace_directory)
        events_path = evidence / "events.jsonl"
        if events_path.exists():
            with events_path.open(encoding="utf-8") as stream:
                for line in stream:
                    event = json.loads(line)
                    if event.get("event") == "run_finished":
                        record["harnessFinishedEvent"] = event
    except (OSError, ValueError, TypeError, KeyError) as error:
        record["evidenceAnalysisError"] = str(error)
    result = record.get("result") or {}
    finished = record.get("harnessFinishedEvent") or {}
    record["harnessVerdict"] = result.get("status", "missing")
    record["harnessFailed"] = (record.get("exitCode") != 0 or record["harnessVerdict"] != "passed"
                               or (bool(finished) and (finished.get("status") != "passed" or finished.get("exitCode") != 0)))
    return record


def analyze_workload(output, source=None):
    source = source if source is not None else GAP.read_json(output / "workload.json")
    if not isinstance(source, dict) or not isinstance(source.get("runs"), list):
        raise ValueError("Existing workload report has no runs list.")
    summary = {**source, "analysisVersion": 2}
    originals = {(item["cycle"], item["kind"]): item for item in source["runs"]}
    if len(originals) != len(source["runs"]):
        raise ValueError("Workload contains duplicate cycle/kind identities.")
    summary["runs"] = [analyze_run(output, originals.get((cycle, kind), {"cycle": cycle, "kind": kind}),
                                   source.get("installedBinarySHA256"))
                       for cycle in range(1, 4) for kind in ("native", "clients")]
    summary["failedHarnessRuns"] = sum(item["harnessFailed"] for item in summary["runs"])
    summary["binaryChanges"] = sum(not item["binaryUnchanged"] for item in summary["runs"])
    summary["missingTraceCount"] = sum(len(item.get("retainedEvidence", {}).get("missingTraces", [])) for item in summary["runs"])
    summary["unmatchedTraceCount"] = sum(len(item.get("retainedEvidence", {}).get("unmatchedTraces", [])) for item in summary["runs"])
    summary["abruptExitMissingTraceCount"] = sum(abrupt_exit_recovery(missing) for item in summary["runs"]
                                               for missing in item.get("retainedEvidence", {}).get("missingTraces", []))
    summary["diagnosticEvidenceFailures"] = sum(
        bool(item.get("evidenceAnalysisError")) or item.get("result") is None
        or not item.get("retainedEvidence", {}).get("fixtureDrawCount")
        or not item.get("retainedEvidence", {}).get("fixtureOperationCount")
        or bool(item.get("retainedEvidence", {}).get("unmatchedTraces"))
        or any(value != 0 for value in item.get("retainedEvidence", {}).get("fixtureOverflow", {}).values())
        or any(not abrupt_exit_recovery(missing) for missing in item.get("retainedEvidence", {}).get("missingTraces", []))
        or any(trace.get("operationOverflow") or trace["analysis"].get("traceOverflow")
               for trace in item.get("retainedEvidence", {}).get("traces", []))
        for item in summary["runs"])
    summary["harnessStatus"] = "passed" if summary["failedHarnessRuns"] == 0 else "failed"
    summary["diagnosticStatus"] = "complete" if not (summary["diagnosticEvidenceFailures"] or summary["binaryChanges"]) else "incomplete"
    summary["status"] = "passed" if not (summary["failedHarnessRuns"] or summary["binaryChanges"] or summary["diagnosticEvidenceFailures"]) else "failed"
    return summary


def reanalyze(directory, destination=None):
    directory = directory.resolve()
    destination = destination.resolve() if destination else directory / "workload-analysis-v2.json"
    if destination.exists():
        raise ValueError(f"Analysis output already exists; choose a new --analysis-out path: {destination}")
    source = GAP.read_json(directory / "workload.json")
    summary = analyze_workload(directory, source)
    summary["sourceWorkloadSHA256"] = digest(directory / "workload.json")
    summary["originalVerdicts"] = {key: source.get(key) for key in
                                   ("status", "harnessStatus", "diagnosticStatus", "failedHarnessRuns", "diagnosticEvidenceFailures", "missingTraceCount")}
    GAP.save(destination, summary)
    print(json.dumps({key: value for key, value in summary.items() if key != "runs"}, indent=2, sort_keys=True))
    return 0 if summary["status"] == "passed" else 1


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
            record = analyze_run(output, record, initial_hash)
            summary["runs"].append(record)
            GAP.save(output / "workload.json", summary)
            print(f"Cycle {cycle}/3 {kind}: exit={record.get('exitCode')}, binaryUnchanged={record['binaryUnchanged']}", flush=True)
    summary = analyze_workload(output, summary)
    GAP.save(output / "workload.json", summary)
    print(json.dumps({key: value for key, value in summary.items() if key != "runs"}, indent=2, sort_keys=True))
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--build-settings", type=Path)
    parser.add_argument("--codex", type=Path)
    parser.add_argument("--claude", type=Path)
    parser.add_argument("--commit")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--reanalyze", type=Path, help="Read an existing downloaded workload without capture or native tools.")
    parser.add_argument("--analysis-out", type=Path, help="New output path; defaults to workload-analysis-v2.json in the workload folder.")
    try:
        args = parser.parse_args()
        capture_arguments = (args.app, args.build_settings, args.codex, args.claude, args.commit, args.out)
        if args.reanalyze:
            if any(capture_arguments):
                parser.error("--reanalyze cannot be combined with capture arguments.")
            sys.exit(reanalyze(args.reanalyze, args.analysis_out))
        if not all(capture_arguments) or args.analysis_out:
            parser.error("Capture requires --app, --build-settings, --codex, --claude, --commit, and --out.")
        sys.exit(run(args))
    except Exception as error:
        print(f"Frame gap workload incomplete: {error}", file=sys.stderr)
        sys.exit(1)
