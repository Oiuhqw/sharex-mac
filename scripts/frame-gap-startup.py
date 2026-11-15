#!/usr/bin/env python3
"""Compare the current writer with a scalar sink after the original native prefix."""
import argparse
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
import time
import traceback
import uuid

ROOT = Path(__file__).resolve().parent


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


NATIVE = module("startup_native", "e2e-agent-capture.py")
WORKLOAD = module("startup_workload", "frame-gap-workload.py")
GAP = WORKLOAD.GAP
ORDER = ("control", "metadata", "metadata", "control")
BYTE_STEP = "byte_limit_finalizes_readable_video"
PREFIX_STEPS = (
    "installed_release_and_desktop_prerequisites", "agent_access_and_screen_recording_permission",
    "build_and_show_independent_fixture", "mcp_initialize_catalog_and_cli_discovery",
    "malformed_payload_invalid_target_and_limits", "nested_socket_frame_leaves_the_app_running",
    "real_window_png_and_no_interactive_side_effects", "real_display_png_and_no_interactive_side_effects",
    "real_region_png_and_no_interactive_side_effects", "window_recording_checkpoint_retry_reconnect_and_markers",
    "real_display_mp4_cross_client_finalization", "real_region_mp4_cross_client_finalization",
    "busy_start_runs_again_with_the_same_request_id", "static_window_recording_covers_explicit_stop",
    "duration_limit_finalizes_readable_video",
)


class PrefixComplete(Exception):
    pass


class StartupMCP(NATIVE.MCP):
    def call(self, operation, arguments=None, request_id=None, error=None):
        if operation == "recording.start" and (arguments or {}).get("maxBytes") == 1048576:
            NATIVE.require(request_id is None and error is None, "Target request unexpectedly has an identity or expected error.")
            request_id = self.run.request_id
        return super().call(operation, arguments, request_id, error)


class StartupEvidence(NATIVE.Evidence):
    @contextmanager
    def step(self, name):
        if name != BYTE_STEP:
            with super().step(name) as step:
                yield step
            return
        self.run.check_prefix()
        if self.run.args.arm == "metadata":
            with super().step("metadata_only_diagnostic_capture") as step:
                self.run.metadata_capture(step)
        else:
            with super().step(name) as step:
                yield step
        raise PrefixComplete()


class StartupRun(NATIVE.Run):
    def __init__(self, args, evidence):
        super().__init__(args, evidence)
        evidence.run = self
        self.request_id = os.environ["SHAREX_FRAME_GAP_STARTUP_REQUEST_ID"]
        self.verified = []

    def connect(self):
        client = StartupMCP(self)
        self.clients.append(client)
        return client

    def validate_media(self, session, mode, kind, *args, **kwargs):
        result = super().validate_media(session, mode, kind, *args, **kwargs)
        self.verified.append({"sessionID": session["id"], "kind": kind, "mode": mode,
                              "verification": result, "finishedMonotonicSeconds": time.monotonic()})
        return result

    def check_prefix(self):
        NATIVE.require([step["name"] for step in self.evidence.steps] == list(PREFIX_STEPS),
                       "The original native prefix changed or ended early.")
        NATIVE.require(all(step["status"] == "passed" for step in self.evidence.steps), "A native prefix step failed.")
        NATIVE.require([item["mode"] for item in self.verified if item["kind"] == "recording"] ==
                       ["window", "display", "region", "window", "display", "window", "region"],
                       "The seven original movie decodes did not run in order.")
        NATIVE.require([item["mode"] for item in self.verified if item["kind"] == "screenshot"] ==
                       ["window", "display", "region", "window"], "The four original PNG decodes did not run in order.")
        NATIVE.require(self.verified[-1]["mode"] == "region" and self.verified[-1]["kind"] == "recording",
                       "The immediate predecessor was not the decoded duration-region movie.")
        self.evidence.emit("startup_prefix_validated", verified=self.verified, appPID=self.app.pid, fixturePID=self.fixture.pid)

    def metadata_capture(self, step):
        self.control("noise", enabled=True)
        started = self.clients[-1].call("recording.start", {**self.selection("window"), "fps": 15,
                                      "maxDurationSeconds": 30, "maxBytes": 1048576})
        NATIVE.require(started["state"] == "recording" and started["acceptedFrames"] == 0,
                       "Metadata startup fabricated accepted encoder frames or did not start.")
        completed = self.terminal(started["id"], timeout=40)
        step.update(session=completed, diagnosticOnly=True, byteLimitE2EPassed=False)
        NATIVE.require(completed["state"] == "failed" and completed["stopReason"] == "diagnostic_metadata_complete"
                       and completed["acceptedFrames"] == 0, "Metadata capture did not end with its explicit diagnostic outcome.")
        NATIVE.require(all(item["state"] != "completed" and not item.get("path") for item in completed["artifacts"]),
                       "Metadata capture published a media artifact.")
        self.validate_manifest(completed)
        self.control("noise", enabled=False)


def run_arm(args):
    args.out.mkdir(parents=True, exist_ok=False)
    evidence = StartupEvidence(args.out)
    run = StartupRun(args, evidence)
    report = {"diagnosticOnly": True, "arm": args.arm, "requestID": run.request_id,
              "status": "failed", "byteLimitE2EPassed": False}
    handlers = {}

    def interrupted(signum, frame):
        raise NATIVE.Failure(f"Startup diagnostic interrupted by signal {signum}.")

    for signum in (signal.SIGINT, signal.SIGTERM):
        handlers[signum] = signal.signal(signum, interrupted)
    try:
        run.preflight()
        run.stories()
        raise NATIVE.Failure("Native stories did not stop at the first noisy capture.")
    except PrefixComplete:
        report.update(status="diagnostic_complete", byteLimitE2EPassed=args.arm == "control")
    except Exception as error:
        report["reason"] = str(error)
        (args.out / "failure.txt").write_text(traceback.format_exc(), encoding="utf-8")
    finally:
        for signum in handlers:
            signal.signal(signum, signal.SIG_IGN)
        cleanup_errors = run.cleanup(failed=report["status"] == "failed")
        if cleanup_errors:
            report.update(status="failed", cleanupErrors=cleanup_errors)
        report.update(steps=evidence.steps, verified=run.verified, sessions=run.sessions)
        GAP.save(args.out / "result.json", report)
        GAP.save(args.out / "metrics.json", run.metrics)
        evidence.emit("run_finished", status=report["status"], byteLimitE2EPassed=report["byteLimitE2EPassed"])
        evidence.events.close()
        for signum, handler in handlers.items():
            signal.signal(signum, handler)
    return 0 if report["status"] == "diagnostic_complete" else 1


def analyze_arm(directory, arm, request_id):
    result = GAP.read_json(directory / "native/result.json") or {}
    events_path = directory / "native/events.jsonl"
    events = [json.loads(line) for line in events_path.read_text(encoding="utf-8").splitlines()] if events_path.exists() else []
    traces = [(path, GAP.read_json(path)) for path in sorted((directory / "traces").glob("*-trace.json"))]
    selected = [(path, trace) for path, trace in traces
                if ((trace.get("context") or {}).get("startupSink") or {}).get("requestID") == request_id]
    errors = []
    prefix = next((event for event in events if event["event"] == "startup_prefix_validated"), None)
    if prefix is None:
        errors.append("Original native prefix was not validated.")
    if len(selected) != 1:
        return {"result": result, "errors": errors + [f"Expected one selected sink trace, found {len(selected)}."]}
    path, trace = selected[0]
    context = trace["context"]
    selection = context["startupSink"]
    callbacks = trace.get("callbacks", [])
    complete = [row for row in callbacks if row["screen"] and row["valid"] and row["image"]
                and row.get("status") == 0 and row.get("pts") is not None]
    draws = GAP.read_json(directory / "native/fixture/draw-trace.json") or []
    history = trace.get("history") or {}
    writer_count = sum(row["name"] == "writer.init" for row in history.get("events", []))
    if selection.get("arm") != arm or selection.get("priorWriters") != 7 or selection.get("completedWriters") != 7:
        errors.append("Sink selection or seven-writer prefix assertion differs.")
    if writer_count != (7 if arm == "metadata" else 8):
        errors.append("The current writer construction count differs from the selected arm.")
    if not draws or not GAP.read_json(directory / "native/fixture/operation-trace.json"):
        errors.append("Fixture traces are absent.")
    for name in ("draw-trace-overflow.txt", "operation-trace-overflow.txt"):
        overflow = directory / "native/fixture" / name
        if not overflow.exists() or int(overflow.read_text().strip()) != 0:
            errors.append(f"Fixture trace is absent or overflowed: {name}.")
    for _, item in traces:
        if item.get("overflow") != 0 or item.get("operationOverflow") != 0 or (item.get("history") or {}).get("overflow") != 0:
            errors.append("A recorder trace or history overflowed or omitted its overflow count.")
        if item.get("streamErrors") or any(row["name"] == "stream.stopFailure" for row in item.get("operations", [])):
            errors.append("A recorder reported a stream start, delivery, or stop error.")
    if len(traces) != 8:
        errors.append(f"Expected eight recorder traces, found {len(traces)}.")
    if len(complete) < 2 or not trace.get("heartbeats"):
        errors.append("The target has fewer than two complete callbacks or no heartbeat.")
    if arm == "metadata":
        if trace.get("writerID") or any(row.get("appended") is not None or row.get("retainedSurfaceID") is not None
                                       or row.get("copyStart") is not None for row in callbacks):
            errors.append("Metadata trace contains writer, retention, or copy work.")
        if result.get("status") != "diagnostic_complete" or result.get("byteLimitE2EPassed") is not False:
            errors.append("Metadata result did not retain its diagnostic-only outcome.")
        if list((directory / "native/session-snapshots" / request_id).rglob("*.mp4")):
            errors.append("Metadata target created a video file.")
    else:
        decoded = [event for event in events if event["event"] == "media_decoded"
                   and event.get("sessionID", "").upper() == request_id]
        if len(decoded) != 1:
            errors.append("Control did not retain its actual target movie decode result.")
    first = complete[0]["pts"] if complete else None
    noisy = [row for row in draws if row.get("noisy") and first is not None and row["entryUptime"] <= first]
    verifier_exits = [event["monotonicSeconds"] for event in events if event["event"] == "command_finished"
                     and any(start["event"] == "command_started" and start.get("log") == event.get("log")
                             and Path(start["command"][0]).name == "verify-agent-media" for start in events)
                     and first is not None and event["monotonicSeconds"] < first]
    pts_intervals = GAP.intervals([row["pts"] for row in complete])
    scale = context["machTimebaseNumerator"] / context["machTimebaseDenominator"] / 1e9
    display_intervals = GAP.intervals([row["displayTime"] * scale for row in complete if row.get("displayTime") is not None])
    if len(display_intervals) != len(pts_intervals):
        errors.append("A complete callback omitted displayTime.")
    if not noisy or not verifier_exits:
        errors.append("First-noise or predecessor verifier timing is absent.")
    first_interval = None
    if pts_intervals:
        start, end = complete[0]["entryUptime"], complete[1]["entryUptime"]
        first_interval = {"drawsCompleted": sum(start < row["exitUptime"] < end for row in draws),
                          "heartbeats": sum(start < value < end for value in trace.get("heartbeats", [])),
                          "firstCallbackSeconds": complete[0]["exitUptime"] - start,
                          "callbackEntryIntervalSeconds": end - start}
    return {"result": result, "errors": errors, "trace": str(path), "selection": selection,
            "writerConstructionCount": writer_count, "analysis": GAP.summarize({"trace": trace}, draws),
            "firstPTSInterval": pts_intervals[0] if pts_intervals else None,
            "firstDisplayTimeInterval": display_intervals[0] if display_intervals else None,
            "firstIntervalContext": first_interval,
            "allPTSIntervals": pts_intervals, "allDisplayTimeIntervals": display_intervals,
            "verifierExitToFirstPTSSeconds": first - max(verifier_exits) if verifier_exits else None,
            "firstNoisyDrawToFirstPTSSeconds": first - noisy[0]["entryUptime"] if noisy else None,
            "statusLaunches": [event for event in events if event["event"] == "command_started"
                               and event.get("command", [])[1:4] == ["--agent", "recording", "status"]
                               and request_id.lower() in [str(part).lower() for part in event["command"]]],
            "firstSecondCallbacks": [row for row in callbacks if first is not None and row["entryUptime"] <= first + 1],
            "prefix": prefix}


def run_comparison(args):
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("Startup diagnostics require a disposable GitHub macOS runner.")
    args.out.mkdir(parents=True, exist_ok=False)
    setup = GAP.read_json(args.setup_result)
    NATIVE.require(setup and setup.get("status") == "passed", "The original setup UI run did not pass.")
    binary = args.app.resolve() / "Contents/MacOS/ShareX"
    initial_hash = WORKLOAD.digest(binary)
    summary = {"diagnosticOnly": True, "commit": args.commit, "order": ORDER, "runs": [],
               "installedBinarySHA256": initial_hash, "fixtureSHA256": WORKLOAD.digest(ROOT / "agent-capture-fixture.swift"),
               "setup": setup, "setupContext": "Original setup UI ran once before arm 1. Arms 2 through 4 reuse its account state; setup is not repeated.",
               "acknowledgementCaveat": "Control acknowledges after first append; metadata acknowledges after first complete callback. CLI polling remains 100 ms after each response. Removed append time changes later launch timing.",
               "scope": "Each arm starts a fresh app and fixture, runs the original native prefix and inline decodes, then stops at the first noisy capture. No maintenance, uninstall, or app replacement runs between arms. Metadata is not decoded-video E2E coverage."}
    GAP.save(args.out / "comparison.json", summary)
    for index, arm in enumerate(ORDER, 1):
        directory = args.out / f"arm-{index:02d}-{arm}"
        directory.mkdir()
        (directory / "traces").mkdir()
        request_id = str(uuid.uuid4()).upper()
        environment = {**os.environ, "SHAREX_FRAME_GAP_WORKLOAD": "1", "SHAREX_FRAME_GAP_FIXTURE_TRACE": "1",
                       "SHAREX_FRAME_GAP_TRACE_DIR": str(directory / "traces"), "SHAREX_FRAME_GAP_HEARTBEAT": "1",
                       "SHAREX_FRAME_GAP_OWNED_BUFFERS": "0", "SHAREX_FRAME_GAP_NV12": "0", "SHAREX_FRAME_GAP_DEEPER_QUEUE": "0",
                       "SHAREX_FRAME_GAP_STARTUP_SINK": arm, "SHAREX_FRAME_GAP_STARTUP_REQUEST_ID": request_id}
        record = {"arm": arm, "index": index, "requestID": request_id}
        try:
            NATIVE.require(WORKLOAD.digest(binary) == initial_hash, "Installed binary changed between arms.")
            record.update(WORKLOAD.bounded_harness([sys.executable, __file__, "--arm", arm, "--app", args.app,
                          "--build-settings", args.build_settings, "--out", directory / "native"],
                          directory / "native.log", environment, 480))
            record.update(analyze_arm(directory, arm, request_id))
            expected_exit = 0 if record.get("result", {}).get("status") == "diagnostic_complete" else 1
            if record.get("exitCode") != expected_exit:
                record.setdefault("errors", []).append("Native process exit differs from its retained result.")
            record["binaryUnchanged"] = WORKLOAD.digest(binary) == initial_hash
        except Exception as error:
            record.setdefault("errors", []).append(str(error))
        summary["runs"].append(record)
        GAP.save(args.out / "comparison.json", summary)
        print(f"Arm {index}/4 {arm}: exit={record.get('exitCode')}, errors={record.get('errors')}", flush=True)
    summary["incompleteArms"] = sum(bool(row.get("errors")) or row.get("timedOut") is not False
                                    or row.get("binaryUnchanged") is not True for row in summary["runs"])
    summary["failedControlGates"] = sum(row["arm"] == "control" and not row.get("result", {}).get("byteLimitE2EPassed")
                                        for row in summary["runs"])
    summary["status"] = "diagnostic_complete" if summary["incompleteArms"] == 0 else "diagnostic_incomplete"
    summary["productionE2EPassed"] = False
    GAP.save(args.out / "comparison.json", summary)
    return 0 if summary["incompleteArms"] == summary["failedControlGates"] == 0 else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.set_defaults(display_name=None)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--build-settings", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--arm", choices=("control", "metadata"))
    parser.add_argument("--setup-result", type=Path)
    parser.add_argument("--commit")
    args = parser.parse_args()
    args.out = args.out.resolve()
    if not args.arm and (not args.setup_result or not args.commit):
        parser.error("Comparison requires --setup-result and --commit.")
    return run_arm(args) if args.arm else run_comparison(args)


if __name__ == "__main__":
    sys.exit(main())
