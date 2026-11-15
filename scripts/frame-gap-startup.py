#!/usr/bin/env python3
"""Compare startup sinks, first-noise timing, or bitmap content after the native prefix."""
import argparse
from collections import Counter
from contextlib import contextmanager
import importlib.util
import json
import math
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
COMPARISONS = {
    "sinks": tuple((arm, None, None) for arm in ORDER),
    "noise-timing": (("metadata", "before", None), ("metadata", "after", None),
                     ("metadata", "after", None), ("metadata", "before", None)),
    "late-noise": (("metadata", "before", None), ("metadata", "late", None),
                   ("metadata", "late", None), ("metadata", "before", None)),
    "bitmap-content": (("metadata", "before", "original"), ("metadata", "before", "constant"),
                       ("metadata", "before", "constant"), ("metadata", "before", "original")),
}
BITMAP_COMPONENT_MASKS = {"original": 255, "constant": 0}
LATE_NOISE_DELAY_SECONDS = 1.0
PRE_NOISE_MINIMUM_COMPLETE_CALLBACKS = 8
PRE_NOISE_MINIMUM_SPAN_SECONDS = 0.75
PRE_NOISE_MAXIMUM_INTERVAL_SECONDS = 0.2
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
        self.metadata_polling = None

    def connect(self):
        client = StartupMCP(self)
        self.clients.append(client)
        return client

    def cli(self, operation, arguments=None, request_id=None, error=None):
        polling = self.metadata_polling
        if polling and operation == "recording.status" and (arguments or {}).get("sessionID") == polling["sessionID"]:
            boundary = time.monotonic()
            deadline = polling["noiseDeadlineUptime"]
            self.evidence.emit("metadata_poll_boundary", requestID=self.request_id, sessionID=polling["sessionID"],
                               pollBoundaryUptime=boundary, noiseDeadlineUptime=deadline)
            if deadline is not None and boundary >= deadline:
                polling["noiseDeadlineUptime"] = None
                self.control("noise", enabled=True)
        return super().cli(operation, arguments, request_id, error)

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
        noise_timing = self.args.noise_timing or "before"
        if noise_timing == "before":
            self.control("noise", enabled=True)
        started = self.clients[-1].call("recording.start", {**self.selection("window"), "fps": 15,
                                      "maxDurationSeconds": 30, "maxBytes": 1048576})
        acknowledged = time.monotonic()
        NATIVE.require(started["state"] == "recording" and started["acceptedFrames"] == 0,
                       "Metadata startup fabricated accepted encoder frames or did not start.")
        self.evidence.emit("metadata_start_acknowledged", requestID=self.request_id, sessionID=started["id"],
                           noiseTiming=noise_timing, acknowledgementUptime=acknowledged)
        if noise_timing == "after":
            self.control("noise", enabled=True)
        deadline = acknowledged + LATE_NOISE_DELAY_SECONDS if noise_timing == "late" else None
        self.metadata_polling = {"sessionID": started["id"], "noiseDeadlineUptime": deadline}
        try:
            completed = self.terminal(started["id"], timeout=40)
        finally:
            self.metadata_polling = None
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
              "noiseTiming": args.noise_timing, "bitmapContent": args.bitmap_content,
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


def analyze_noise_timing(timing, request_id, trace, complete, draws, operations, events, status_launches, errors):
    noisy = [row for row in draws if row.get("noisy")]
    requests = [event for event in events if event["event"] == "fixture_command_requested"
                and event.get("action") == "noise" and event.get("values", {}).get("enabled") is True]
    controls = [event for event in events if event["event"] == "fixture_command"
                and event.get("action") == "noise" and event.get("values", {}).get("enabled") is True]
    starts = [event for event in events if event["event"] == "agent_operation_request"
              and event.get("operation") == "recording.start" and event.get("requestID") == request_id]
    acknowledgements = [event for event in events if event["event"] == "metadata_start_acknowledged"
                        and event.get("requestID") == request_id and event.get("noiseTiming") == timing]
    if not noisy or not complete or any(len(values) != 1 for values in (requests, controls, starts, acknowledgements)):
        errors.append("Noise timing requires one first-use command, target start, acknowledgement, and noisy draw trace.")
        return {"noiseTiming": timing}
    noise = noisy[0]["entryUptime"]
    requested = requests[0]["monotonicSeconds"]
    controlled = controls[0]["monotonicSeconds"]
    started = starts[0]["monotonicSeconds"]
    acknowledged = acknowledgements[0].get("acknowledgementUptime", acknowledgements[0]["monotonicSeconds"])
    if not requested <= noise <= noisy[0]["exitUptime"] <= controlled:
        errors.append("The first noisy draw did not occur inside the first noise control command.")
    if not started <= complete[0]["entryUptime"] <= acknowledged:
        errors.append("The first complete callback did not occur between target start and acknowledgement.")
    if timing == "before" and not controlled <= started:
        errors.append("Before-start noise control did not finish before the target request.")
    if timing in ("after", "late") and not acknowledged <= requested:
        errors.append("After-ack noise control started before the first complete acknowledgement.")
    first_status_bound = acknowledged if timing == "late" else max(acknowledged, controlled)
    if not status_launches or status_launches[0]["monotonicSeconds"] < first_status_bound:
        errors.append("The first target status launch is absent or precedes acknowledgement and noise control.")
    boundaries = [event for event in events if event["event"] == "metadata_poll_boundary"
                  and event.get("requestID") == request_id]
    deadline = acknowledged + LATE_NOISE_DELAY_SECONDS if timing == "late" else None
    trigger = None
    if timing == "late":
        eligible = [event for event in boundaries if event["pollBoundaryUptime"] >= deadline]
        trigger = eligible[0]["pollBoundaryUptime"] if eligible else None
        scheduled = [event for event in boundaries if event.get("noiseDeadlineUptime") is not None]
        if (not scheduled or not eligible or scheduled[-1] != eligible[0]
                or any(abs(event["noiseDeadlineUptime"] - deadline) > 1e-6 for event in scheduled)
                or not deadline <= trigger <= requested):
            errors.append("Late noise did not start at the first polling boundary at or after its fixed deadline.")
        if not status_launches or not acknowledged <= status_launches[0]["monotonicSeconds"] < deadline:
            errors.append("Late noise has no target status launch before its deadline.")
    if complete[0]["pts"] >= noise + 1 or complete[-1]["pts"] < noise + 1:
        errors.append("The metadata capture does not cover the first second after the first noisy draw.")

    def overlaps(row):
        return row["end"] > noise and row["start"] < noise + 1

    callbacks = trace["callbacks"]
    complete_pts = GAP.intervals([row["pts"] for row in complete])
    all_source = [row for row in callbacks if row.get("pts") is not None]
    all_pts = GAP.intervals([row["pts"] for row in all_source])
    pts = [row for row in complete_pts if overlaps(row)]
    window_all_pts = [row for row in all_pts if overlaps(row)]
    pre_complete = [row for row in complete if row["exitUptime"] <= noise and row["pts"] < noise]
    pre_all_source = [row for row in all_source if row["exitUptime"] <= noise and row["pts"] < noise]
    pre_callbacks = [row for row in callbacks if row["exitUptime"] <= noise]
    pre_complete_intervals = GAP.intervals([row["pts"] for row in pre_complete])
    pre_all_intervals = GAP.intervals([row["pts"] for row in pre_all_source])
    pre_span = pre_complete[-1]["pts"] - pre_complete[0]["pts"] if pre_complete else 0
    last_pts_age = noise - pre_complete[-1]["pts"] if pre_complete else None
    last_exit_age = noise - pre_complete[-1]["exitUptime"] if pre_complete else None
    pre_maximum = GAP.maximum(pre_complete_intervals)
    qualified = (len(pre_complete) >= PRE_NOISE_MINIMUM_COMPLETE_CALLBACKS
                 and pre_span >= PRE_NOISE_MINIMUM_SPAN_SECONDS and pre_maximum is not None
                 and 0 < pre_maximum["seconds"] <= PRE_NOISE_MAXIMUM_INTERVAL_SECONDS
                 and last_pts_age <= PRE_NOISE_MAXIMUM_INTERVAL_SECONDS
                 and all(row["seconds"] > 0 for row in pre_complete_intervals))
    if timing == "late" and not qualified:
        errors.append("Late noise lacks the required regular pre-noise complete capture cadence.")

    def first_long_interval(intervals):
        for index, interval in enumerate(intervals):
            if interval["seconds"] > GAP.QUALITY_GAP_SECONDS:
                return {**interval, "index": index, "startRelativeToNoiseSeconds": interval["start"] - noise,
                        "endRelativeToNoiseSeconds": interval["end"] - noise,
                        "position": "before" if interval["end"] <= noise else "after" if interval["start"] >= noise else "crossing"}
        return None

    callback_intervals = [row for row in GAP.intervals([row["entryUptime"] for row in callbacks]) if overlaps(row)]
    complete_callback_intervals = [row for row in GAP.intervals([row["entryUptime"] for row in complete]) if overlaps(row)]
    scale = trace["context"]["machTimebaseNumerator"] / trace["context"]["machTimebaseDenominator"] / 1e9
    display = [row for row in GAP.intervals([row["displayTime"] * scale for row in complete
                                            if row.get("displayTime") is not None]) if overlaps(row)]
    spans = []
    pending = {}
    for row in operations:
        if row["phase"] == "begin":
            pending[row["name"]] = row["uptime"]
        elif row["name"] in pending:
            start = pending.pop(row["name"])
            spans.append({"name": row["name"], "start": start, "end": row["uptime"], "seconds": row["uptime"] - start})
    window_spans = [row for row in spans if overlaps(row)]
    window_draws = [row for row in draws if row["exitUptime"] > noise and row["entryUptime"] < noise + 1]
    draw_intervals = [row for row in GAP.intervals([row["entryUptime"] for row in draws]) if overlaps(row)]
    target_spans = [row for row in spans if row["end"] > started and row["start"] < complete[-1]["exitUptime"]]
    if not window_spans or not window_draws:
        errors.append("The post-noise window has no fixture operation spans or draws.")
    return {"noiseTiming": timing, "firstNoiseUptime": noise, "firstCapturePTS": complete[0]["pts"],
            "targetStartUptime": started, "metadataAcknowledgementUptime": acknowledged,
            "noiseDeadlineUptime": deadline, "noiseTriggerPollBoundaryUptime": trigger,
            "deadlineToNoiseCommandSeconds": requested - deadline if deadline is not None else None,
            "noiseCommandRequestedUptime": requested, "noiseCommandCompletedUptime": controlled,
            "noiseControlSeconds": controlled - requested,
            "acknowledgementToNoiseCommandSeconds": requested - acknowledged,
            "acknowledgementToFirstStatusLaunchSeconds": status_launches[0]["monotonicSeconds"] - acknowledged if status_launches else None,
            "noiseControlToFirstStatusLaunchSeconds": status_launches[0]["monotonicSeconds"] - controlled if status_launches else None,
            "statusPollBoundaries": boundaries,
            "preNoiseCapture": {"qualified": qualified, "end": noise, "completeCallbacks": len(pre_complete),
                "allSourceCallbacks": len(pre_all_source), "completeSourceSpanSeconds": pre_span,
                "lastCompletePTSAgeSeconds": last_pts_age, "lastCompleteCallbackExitAgeSeconds": last_exit_age,
                "allCallbacks": len(pre_callbacks), "callbackStatusCounts": dict(Counter(str(row.get("status")) for row in pre_callbacks)),
                "completeSourcePTSIntervals": pre_complete_intervals, "allSourcePTSIntervals": pre_all_intervals,
                "maximumCompleteSourcePTSInterval": pre_maximum,
                "maximumAllSourcePTSInterval": GAP.maximum(pre_all_intervals)},
            "completeSourceIntervalsCrossingNoise": [row for row in complete_pts if row["start"] < noise < row["end"]],
            "allSourceIntervalsCrossingNoise": [row for row in all_pts if row["start"] < noise < row["end"]],
            "sourceLongIntervalThresholdSeconds": GAP.QUALITY_GAP_SECONDS,
            "allSourcePTSIntervals": all_pts, "maximumAllSourcePTSInterval": GAP.maximum(all_pts),
            "maximumCompleteSourcePTSInterval": GAP.maximum(complete_pts),
            "firstLongCompleteSourceInterval": first_long_interval(complete_pts),
            "firstLongAllSourceInterval": first_long_interval(all_pts),
            "maximumTargetFixtureOperationSpan": GAP.maximum(target_spans),
            "postNoiseFirstSecond": {"start": noise, "end": noise + 1, "ptsIntervals": pts,
                "allSourcePTSIntervals": window_all_pts,
                "maximumAllSourcePTSInterval": GAP.maximum(window_all_pts),
                "displayTimeIntervals": display, "callbackEntryIntervals": callback_intervals,
                "completeCallbackEntryIntervals": complete_callback_intervals,
                "maximumPTSInterval": GAP.maximum(pts), "maximumDisplayTimeInterval": GAP.maximum(display),
                "maximumCallbackEntryInterval": GAP.maximum(callback_intervals),
                "maximumCompleteCallbackEntryInterval": GAP.maximum(complete_callback_intervals),
                "fixtureOperationSpans": window_spans, "maximumFixtureOperationSpan": GAP.maximum(window_spans),
                "fixtureDraws": window_draws, "maximumFixtureDrawEntryInterval": GAP.maximum(draw_intervals),
                "maximumFixtureDrawSeconds": max((row["exitUptime"] - row["entryUptime"] for row in window_draws), default=None),
                "heartbeats": [value for value in trace.get("heartbeats", []) if noise <= value <= noise + 1]},
            "callbacksAroundFirstNoise": [row for row in callbacks if noise - 1 <= row["entryUptime"] <= noise + 1]}


def analyze_bitmap_content(content, result, draws, errors):
    expected = {"componentMask": BITMAP_COMPONENT_MASKS[content], "width": 640, "height": 56,
                "bitsPerComponent": 8, "bitsPerPixel": 32, "bytesPerRow": 2560, "byteCount": 143360,
                "bitmapInfo": 5, "colorSpaceModel": 1, "shouldInterpolate": False}
    if result.get("bitmapContent") != content:
        errors.append("The native result does not identify the requested bitmap content.")
    noisy = [row for row in draws if row.get("noisy")]
    proofs = [row for row in draws if row.get("bitmap") is not None]
    if not noisy or noisy != proofs:
        errors.append("Every noisy draw must contain a successful bitmap draw, with none in the non-noisy prefix.")
    for row in proofs:
        proof = row["bitmap"]
        if any(proof.get(key) != value for key, value in expected.items()):
            errors.append("Bitmap content mask or actual image layout differs from the selected condition.")
            break
        destination = proof.get("destination", [])
        if len(destination) != 4 or any(not math.isclose(actual, value, abs_tol=1e-9)
                                       for actual, value in zip(destination, (0, 422.4, 640, 57.6))):
            errors.append("Bitmap draw destination differs from the original scaled rectangle.")
            break
        if not row["entryUptime"] <= proof.get("entryUptime", -1) <= proof.get("exitUptime", -1) <= row["exitUptime"]:
            errors.append("Bitmap draw timing is absent or lies outside the fixture draw.")
            break
        count = proof.get("rgbNonzeroCount")
        if (type(count) is not int or not 0 <= count <= 640 * 56 * 3
                or (count == 0) != (content == "constant")):
            errors.append("Bitmap RGB byte evidence does not match the selected content.")
            break
        tick = row.get("tick")
        if type(tick) is not int or tick < 0:
            errors.append("Bitmap draw omitted its source tick.")
            break
        seed = tick + 1
        expected_nonzero = 0
        for _ in range(640 * 56):
            seed = (seed * 6364136223846793005 + 1442695040888963407) & ((1 << 64) - 1)
            expected_nonzero += sum(((seed >> shift) & expected["componentMask"]) != 0 for shift in (24, 32, 40))
        if proof.get("finalSeed") != seed:
            errors.append("Bitmap final seed does not prove the unchanged complete LCG loop.")
            break
        if count != expected_nonzero:
            errors.append("Bitmap RGB byte count differs from the complete LCG generation.")
            break
    return {"bitmapContent": content, "bitmapDrawCount": len(proofs),
            "firstBitmapDraw": proofs[0] if proofs else None}


def analyze_arm(directory, arm, request_id, noise_timing=None, bitmap_content=None):
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
    fixture_operations = GAP.read_json(directory / "native/fixture/operation-trace.json") or []
    history = trace.get("history") or {}
    writer_count = sum(row["name"] == "writer.init" for row in history.get("events", []))
    if selection.get("arm") != arm or selection.get("priorWriters") != 7 or selection.get("completedWriters") != 7:
        errors.append("Sink selection or seven-writer prefix assertion differs.")
    if writer_count != (7 if arm == "metadata" else 8):
        errors.append("The current writer construction count differs from the selected arm.")
    if not draws or not fixture_operations:
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
        if noise_timing and result.get("noiseTiming") != noise_timing:
            errors.append("The native result does not identify the requested noise timing.")
    else:
        decoded = [event for event in events if event["event"] == "media_decoded"
                   and event.get("sessionID", "").upper() == request_id]
        if len(decoded) != 1:
            errors.append("Control did not retain its actual target movie decode result.")
    first = complete[0]["pts"] if complete else None
    noisy = [row for row in draws if row.get("noisy") and first is not None
             and (noise_timing in ("after", "late") or row["entryUptime"] <= first)]
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
    status_launches = [event for event in events if event["event"] == "command_started"
                       and event.get("command", [])[1:4] == ["--agent", "recording", "status"]
                       and request_id.lower() in [str(part).lower() for part in event["command"]]]
    timing_analysis = analyze_noise_timing(noise_timing, request_id, trace, complete, draws, fixture_operations,
                                          events, status_launches, errors) if noise_timing else {}
    bitmap_analysis = analyze_bitmap_content(bitmap_content, result, draws, errors) if bitmap_content else {}
    return {"result": result, "errors": errors, "trace": str(path), "selection": selection,
            **timing_analysis, **bitmap_analysis,
            "writerConstructionCount": writer_count, "analysis": GAP.summarize({"trace": trace}, draws),
            "firstPTSInterval": pts_intervals[0] if pts_intervals else None,
            "firstDisplayTimeInterval": display_intervals[0] if display_intervals else None,
            "firstIntervalContext": first_interval,
            "allPTSIntervals": pts_intervals, "allDisplayTimeIntervals": display_intervals,
            "verifierExitToFirstPTSSeconds": first - max(verifier_exits) if verifier_exits else None,
            "firstNoisyDrawToFirstPTSSeconds": first - noisy[0]["entryUptime"] if noisy else None,
            "statusLaunches": status_launches,
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
    fixture_source = ROOT / "agent-capture-fixture.swift"
    fixture_hash = WORKLOAD.digest(fixture_source)
    fixture_binary_hash = None
    comparison = args.comparison
    arms = COMPARISONS[comparison]
    summary = {"diagnosticOnly": True, "commit": args.commit, "comparison": comparison,
               "order": [content or timing or arm for arm, timing, content in arms], "runs": [],
               "installedBinarySHA256": initial_hash, "fixtureSHA256": fixture_hash,
               "setup": setup, "setupContext": "Original setup UI ran once before arm 1. Arms 2 through 4 reuse its account state; setup is not repeated.",
               "acknowledgementCaveat": "Control acknowledges after first append; metadata acknowledges after first complete callback. CLI polling remains 100 ms after each response. Removed append time changes later launch timing.",
               "scope": "Each arm starts a fresh app and fixture, runs the original native prefix and inline decodes, then stops at the first noisy capture. No maintenance, uninstall, or app replacement runs between arms. Metadata is not decoded-video E2E coverage."}
    if comparison == "noise-timing":
        summary["acknowledgementCaveat"] = "Every target uses metadata and acknowledges its first complete callback. The after arm waits for the noise control response before the first CLI status launch. Report this added launch delay; the inherited 100 ms polling delay and three-second observation remain unchanged."
    if comparison == "late-noise":
        summary["acknowledgementCaveat"] = "Every target uses metadata and starts native CLI polling immediately after acknowledgement. Late noise runs on the first polling boundary at or after acknowledgement plus one second. The noise control delays that boundary's status launch. Native polling still waits 100 ms after each response; the three-second observation is fixed."
        summary["lateNoiseQualification"] = {"delayAfterAcknowledgementSeconds": LATE_NOISE_DELAY_SECONDS,
            "minimumCompleteCallbacks": PRE_NOISE_MINIMUM_COMPLETE_CALLBACKS,
            "minimumCompleteSourceSpanSeconds": PRE_NOISE_MINIMUM_SPAN_SECONDS,
            "maximumCompleteSourceIntervalSeconds": PRE_NOISE_MAXIMUM_INTERVAL_SECONDS,
            "maximumLastCompletePTSAgeSeconds": PRE_NOISE_MAXIMUM_INTERVAL_SECONDS,
            "requiredPostNoiseSeconds": 1.0, "bound": "Actual first noisy draw entry uptime. Qualification never delays noise."}
    if comparison == "bitmap-content":
        summary["acknowledgementCaveat"] = "Every target uses metadata and first draws its bitmap before recording.start. Native polling and the fixed three-second observation are unchanged. Only the runtime RGB component mask differs."
        summary["interpretation"] = {
            "constantReproduces": "High-entropy changing RGB content is not necessary for the observed source gap.",
            "onlyOriginalRepeats": "Both original arms reproduce and both constant arms are clean. This supports a content-dependent presentation boundary, not a specific compositor or GPU mechanism.",
            "mixedCleanOrIncomplete": "Mixed repetitions, all-clean results, or incomplete evidence permit no clean paired causal claim.",
            "followOn": "Use a system profile to locate the unresolved presentation or source work. No production fix follows from timing alone."}
    GAP.save(args.out / "comparison.json", summary)
    for index, (arm, noise_timing, bitmap_content) in enumerate(arms, 1):
        label = bitmap_content or noise_timing or arm
        directory = args.out / f"arm-{index:02d}-{label}"
        directory.mkdir()
        (directory / "traces").mkdir()
        request_id = str(uuid.uuid4()).upper()
        environment = {**os.environ, "SHAREX_FRAME_GAP_WORKLOAD": "1", "SHAREX_FRAME_GAP_FIXTURE_TRACE": "1",
                       "SHAREX_FRAME_GAP_TRACE_DIR": str(directory / "traces"), "SHAREX_FRAME_GAP_HEARTBEAT": "1",
                       "SHAREX_FRAME_GAP_OWNED_BUFFERS": "0", "SHAREX_FRAME_GAP_NV12": "0", "SHAREX_FRAME_GAP_DEEPER_QUEUE": "0",
                       "SHAREX_FRAME_GAP_STARTUP_SINK": arm, "SHAREX_FRAME_GAP_STARTUP_REQUEST_ID": request_id,
                       "SHAREX_FRAME_GAP_BITMAP_COMPONENT_MASK": str(BITMAP_COMPONENT_MASKS[bitmap_content or "original"])}
        record = {"arm": arm, "noiseTiming": noise_timing, "bitmapContent": bitmap_content,
                  "index": index, "requestID": request_id}
        try:
            NATIVE.require(WORKLOAD.digest(binary) == initial_hash, "Installed binary changed between arms.")
            NATIVE.require(WORKLOAD.digest(fixture_source) == fixture_hash, "Fixture source changed between arms.")
            arguments = [sys.executable, __file__, "--arm", arm, "--app", args.app,
                         "--build-settings", args.build_settings, "--out", directory / "native"]
            if noise_timing:
                arguments.extend(["--comparison", comparison, "--noise-timing", noise_timing])
            if bitmap_content:
                arguments.extend(["--bitmap-content", bitmap_content])
            record.update(WORKLOAD.bounded_harness(arguments,
                          directory / "native.log", environment, 480))
            record.update(analyze_arm(directory, arm, request_id, noise_timing, bitmap_content))
            expected_exit = 0 if record.get("result", {}).get("status") == "diagnostic_complete" else 1
            if record.get("exitCode") != expected_exit:
                record.setdefault("errors", []).append("Native process exit differs from its retained result.")
            record["binaryUnchanged"] = WORKLOAD.digest(binary) == initial_hash
            if bitmap_content:
                record["fixtureSourceUnchanged"] = WORKLOAD.digest(fixture_source) == fixture_hash
                record["fixtureBinarySHA256"] = WORKLOAD.digest(directory / "native/agent-capture-fixture")
                if fixture_binary_hash is None:
                    fixture_binary_hash = record["fixtureBinarySHA256"]
                    summary["fixtureBinarySHA256"] = fixture_binary_hash
                if not record["fixtureSourceUnchanged"] or record["fixtureBinarySHA256"] != fixture_binary_hash:
                    record.setdefault("errors", []).append("Fixture source or binary changed between bitmap content arms.")
        except Exception as error:
            record.setdefault("errors", []).append(str(error))
        summary["runs"].append(record)
        GAP.save(args.out / "comparison.json", summary)
        print(f"Arm {index}/4 {label}: exit={record.get('exitCode')}, errors={record.get('errors')}", flush=True)
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
    parser.add_argument("--comparison", choices=COMPARISONS, default="sinks")
    parser.add_argument("--noise-timing", choices=("before", "after", "late"))
    parser.add_argument("--bitmap-content", choices=BITMAP_COMPONENT_MASKS)
    parser.add_argument("--setup-result", type=Path)
    parser.add_argument("--commit")
    args = parser.parse_args()
    args.out = args.out.resolve()
    if (args.arm or args.noise_timing or args.bitmap_content) and (
            args.arm, args.noise_timing, args.bitmap_content) not in COMPARISONS[args.comparison]:
        parser.error("Arm, noise timing, and bitmap content must match the selected comparison.")
    if args.arm and os.environ.get("SHAREX_FRAME_GAP_BITMAP_COMPONENT_MASK", "255") != str(BITMAP_COMPONENT_MASKS[args.bitmap_content or "original"]):
        parser.error("Bitmap content must match the fixture component mask environment.")
    if not args.arm and (not args.setup_result or not args.commit):
        parser.error("Comparison requires --setup-result and --commit.")
    return run_arm(args) if args.arm else run_comparison(args)


if __name__ == "__main__":
    sys.exit(main())
