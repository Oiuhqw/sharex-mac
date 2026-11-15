#!/usr/bin/env python3
"""Replay matched recording history while varying only the measured status route."""
import argparse
import importlib.util
import json
import math
import os
from pathlib import Path, PurePosixPath
import platform
import signal
import socket
import sys
import time
import traceback
import uuid


ROOT = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


NATIVE = load("replay_native", "e2e-agent-capture.py")
WORKLOAD = load("replay_workload", "frame-gap-workload.py")
GAP = WORKLOAD.GAP
PAIR_COUNT = 16
SLOT_COUNT = 16
SLOT_SECONDS = 0.25
TERMINAL_SECONDS = 40
DRAIN_SECONDS = 21
PREDECESSORS = (
    {"name": "animated-display", "mode": "display", "hold": 1.2, "duration": 30,
     "startRoute": "cli", "stopRoute": "mcp", "minimum": 1, "maximum": 8, "stopReason": "user_stop"},
    {"name": "static-window", "mode": "window", "hold": 2.5, "duration": 20,
     "startRoute": "mcp", "stopRoute": "cli", "minimum": 0, "maximum": 10, "stopReason": "user_stop"},
    {"name": "duration-region", "mode": "region", "hold": None, "duration": 3,
     "startRoute": "cli", "minimum": 2.6, "maximum": 3.7, "stopReason": "duration_limit"},
)
MEASURED = {"name": "noisy-window", "mode": "window", "hold": None, "duration": 30,
            "startRoute": "mcp", "minimum": 0.5, "maximum": 30, "stopReason": "byte_limit"}


class ReplayInterrupted(NATIVE.Failure):
    pass


def plan():
    return [{"pair": pair, "arm": arm, "position": position, "role": role, "recipe": recipe,
             "path": f"captures/{pair:02d}-{position}-{arm}/{recipe['name']}",
             "status": "not_run", "infrastructureErrors": []}
            for pair in range(1, PAIR_COUNT + 1)
            for position, arm in enumerate(("cli", "direct") if pair % 2 else ("direct", "cli"), 1)
            for role, recipe in [("predecessor", value) for value in PREDECESSORS] + [("measured", MEASURED)]]


def status_slots(anchor, request, clock=time.monotonic, sleep=time.sleep):
    slots = []
    previous_end = anchor
    for index in range(SLOT_COUNT):
        planned = anchor + index * SLOT_SECONDS
        row = {"index": index, "plannedMonotonicSeconds": planned}
        slots.append(row)
        if index and previous_end > planned:
            row.update(skipped=True, reason="previous_request_in_flight", observedMonotonicSeconds=clock())
            continue
        sleep(max(0, planned - clock()))
        actual = clock()
        if actual >= planned + SLOT_SECONDS:
            row.update(skipped=True, reason="scheduler_late", observedMonotonicSeconds=actual)
            continue
        request_id = str(uuid.uuid4())
        row.update(skipped=False, requestID=request_id, actualMonotonicSeconds=actual)
        try:
            result = request(request_id)
            row.update(state=result["state"], sessionID=result["id"], acceptedFrames=result.get("acceptedFrames"))
        except ReplayInterrupted:
            raise
        except Exception as error:
            row["error"] = str(error)
        previous_end = clock()
        row["endMonotonicSeconds"] = previous_end
    sleep(max(0, anchor + SLOT_COUNT * SLOT_SECONDS - clock()))
    return slots


def socket_response(connection, request, pid):
    NATIVE.require(connection.getsockopt(0, 2) == pid, "The agent socket belongs to another process.")
    body = json.dumps(request, separators=(",", ":")).encode()
    connection.sendall(len(body).to_bytes(4, "big") + body)
    with connection.makefile("rb") as reader:
        header = reader.read(4)
        NATIVE.require(len(header) == 4, "Agent response frame header is incomplete.")
        size = int.from_bytes(header, "big")
        NATIVE.require(0 < size <= 1_048_576, "Agent response exceeds the transport frame limit.")
        response = reader.read(size)
        NATIVE.require(len(response) == size, "Agent response frame body is incomplete.")
    return json.loads(response)


class ReplayRun(NATIVE.Run):
    validation_record = None

    def __init__(self, args, evidence):
        super().__init__(args, evidence)
        self.trace_files_seen = set()

    def command(self, command, **kwargs):
        if self.validation_record is not None and Path(command[0]).name == "verify-agent-media":
            NATIVE.require(GAP.read_json(Path(command[2])) == self.validation_record["expectation"],
                           "Deferred media expectation differs from its capture-time snapshot.")
            result = super().command(command, **kwargs)
            self.validation_record["verifierProcess"] = result
            return result
        return super().command(command, **kwargs)

    def require_owned_app(self):
        NATIVE.require(self.app.poll() is None, "The installed ShareX app exited.")
        expected = [str(self.app.pid)]
        for client in self.clients:
            if client.process.poll() is None:
                NATIVE.require(any(child is client.process for child in self.children),
                               "Live MCP client is not an owned child process.")
                expected.append(str(client.process.pid))
        running = self.command(["/usr/bin/pgrep", "-x", self.binary.name], timeout=5, check=False)
        pids = running["stdout"].split()
        NATIVE.require(running["exitCode"] == 0 and sorted(pids) == sorted(expected),
                       f"Expected the owned ShareX app and live MCP PIDs {expected}; found {pids} "
                       f"with process check exit code {running['exitCode']}.")

    def direct(self, operation, session_id, request_id=None, timeout=25):
        NATIVE.require(self.app.poll() is None, "Owned app exited before the direct request.")
        NATIVE.require(session_id in self.owned_session_ids, "Direct request does not name an owned capture.")
        request_id = request_id or str(uuid.uuid4())
        request = {"version": 1, "id": request_id, "operation": operation, "arguments": {"sessionID": session_id}}
        self.evidence.emit("direct_request", request=request, monotonicSeconds=time.monotonic())
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(timeout)
            connection.connect(str(self.agent_endpoint()))
            response = socket_response(connection, request, self.app.pid)
        self.evidence.emit("direct_response", response=response, monotonicSeconds=time.monotonic())
        result = NATIVE.decode_response(response, request_id)
        NATIVE.require(uuid.UUID(result["id"]) == uuid.UUID(session_id), "Status returned a different capture.")
        return result

    def direct_terminal(self, session_id, deadline):
        while time.monotonic() < deadline:
            result = self.direct("recording.status", session_id, timeout=min(25, deadline - time.monotonic()))
            if result["state"] in NATIVE.TERMINAL:
                return result
            time.sleep(min(SLOT_SECONDS, max(0, deadline - time.monotonic())))
        raise NATIVE.Failure("Owned capture did not reach terminal state within its deadline.")


def wait_for_trace(directory, session, seen=None, clock=time.monotonic, sleep=time.sleep):
    expected = {(str(uuid.UUID(session["id"])).upper(), str(uuid.UUID(item["id"])).upper())
                for item in session.get("artifacts", []) if item.get("kind") == "recording"}
    NATIVE.require(expected, "Terminal capture contains no recording artifact to join.")
    started = clock()
    seen = seen if seen is not None else set()
    found, paths = set(), []
    while clock() - started < 5:
        for path in directory.glob("*-trace.json"):
            if path.name in seen:
                continue
            trace = GAP.read_json(path)
            seen.add(path.name)
            video = PurePosixPath((trace.get("context") or {}).get("videoPath", ""))
            try:
                identity = (str(uuid.UUID(video.parent.parent.name)).upper(), str(uuid.UUID(video.parent.name)).upper())
            except ValueError:
                continue
            if identity in expected:
                found.add(identity)
                paths.append(path.name)
        if found == expected:
            return {"seconds": clock() - started, "files": paths, "complete": True}
        sleep(0.05)
    return {"seconds": clock() - started, "files": paths, "complete": False}


def capture(run, client, record, output):
    recipe = record["recipe"]
    directory = output / record["path"]
    directory.mkdir(parents=True)
    record.update(status="running", sessionID=str(uuid.uuid4()), beginMonotonicSeconds=time.monotonic())
    session_id = record["sessionID"]
    terminal = None
    started = False
    try:
        run.require_owned_app()
        run.control("mode", mode="static" if recipe["name"] == "static-window" else "animated")
        run.control("stage", stage=0)
        run.control("noise", enabled=record["role"] == "measured")
        record["fixtureBeforeStart"] = run.fixture_state()
        options = {**run.selection(recipe["mode"]), "fps": 15, "maxDurationSeconds": recipe["duration"]}
        if record["role"] == "measured":
            options["maxBytes"] = 1048576
        record.update(options=options, startRequestedMonotonicSeconds=time.monotonic())
        started = True
        response = (run.cli if recipe["startRoute"] == "cli" else client.call)("recording.start", options, session_id)
        anchor = time.monotonic()
        record.update(startAcknowledgedMonotonicSeconds=anchor, startResponse=response)
        NATIVE.require(uuid.UUID(response["id"]) == uuid.UUID(session_id), "Start changed the owned capture ID.")
        NATIVE.require(response["state"] == "recording" and response["acceptedFrames"] >= 1,
                       "Recording start did not acknowledge an accepted frame.")
        if record["role"] == "measured":
            def request(request_id):
                value = (run.cli("recording.status", {"sessionID": session_id}, request_id)
                         if record["arm"] == "cli" else run.direct("recording.status", session_id, request_id))
                NATIVE.require(uuid.UUID(value["id"]) == uuid.UUID(session_id), "Status changed the owned capture ID.")
                return value
            record["slots"] = status_slots(anchor, request)
            record["infrastructureErrors"].extend(row["error"] for row in record["slots"] if "error" in row)
            terminal = run.direct_terminal(session_id, anchor + TERMINAL_SECONDS)
        elif recipe["hold"] is not None:
            before = run.control("observe") if recipe["name"] == "static-window" else None
            time.sleep(recipe["hold"])
            stop_requested = run.control("observe") if before else None
            record["stopRequestedMonotonicSeconds"] = time.monotonic()
            terminal = (run.cli if recipe["stopRoute"] == "cli" else client.call)("recording.stop", {"sessionID": session_id})
            if before:
                after = run.control("observe")
                record["staticWindow"] = {"before": before, "stopRequested": stop_requested, "after": after}
                NATIVE.static_window_proof(before, stop_requested, after)
        else:
            terminal = run.terminal(session_id)
        record["terminalObservedMonotonicSeconds"] = time.monotonic()
        NATIVE.require(terminal["state"] == "completed" and terminal.get("stopReason") == recipe["stopReason"],
                       f"Expected completed/{recipe['stopReason']}, received {terminal['state']}/{terminal.get('stopReason')}.")
    except ReplayInterrupted as error:
        record["infrastructureErrors"].append(str(error))
        raise
    except Exception as error:
        record["infrastructureErrors"].append(str(error))
    finally:
        if started and (terminal is None or terminal.get("state") not in NATIVE.TERMINAL):
            record["cleanupRequestedMonotonicSeconds"] = time.monotonic()
            try:
                terminal = run.direct("recording.stop", session_id)
                if terminal["state"] not in NATIVE.TERMINAL:
                    terminal = run.direct_terminal(session_id, time.monotonic() + TERMINAL_SECONDS)
                record["cleanupTerminal"] = terminal
            except Exception as error:
                record["infrastructureErrors"].append(f"Owned capture cleanup failed: {error}")
        record["terminal"] = terminal
        record["safeToContinue"] = not started or bool(terminal and terminal.get("state") in NATIVE.TERMINAL)
        record["endMonotonicSeconds"] = time.monotonic()
        if terminal and terminal.get("state") in NATIVE.TERMINAL:
            GAP.save(directory / "terminal.json", terminal)
            try:
                record["traceFlush"] = wait_for_trace(Path(os.environ["SHAREX_FRAME_GAP_TRACE_DIR"]), terminal, run.trace_files_seen)
                NATIVE.require(record["traceFlush"]["complete"], "Capture trace was not flushed within five seconds.")
            except Exception as error:
                record["infrastructureErrors"].append(f"Capture trace flush failed: {error}")
            try:
                target = run.window_target if recipe["mode"] == "window" else run.display_target
                record["expectation"] = NATIVE.media_expectation(run.geometry, target, recipe["mode"], "recording", [0],
                    recipe["minimum"], recipe["maximum"], static_window=record.get("staticWindow"))
                GAP.save(directory / "expectation.json", record["expectation"])
            except Exception as error:
                record["infrastructureErrors"].append(f"Capture-time expectation failed: {error}")
        record["status"] = "failed" if record["infrastructureErrors"] else "collected"
        record["endMonotonicSeconds"] = time.monotonic()
        GAP.save(directory / "capture.json", record)
    return record["safeToContinue"]


def verify_captures(run, records, output):
    for record in records:
        terminal = record.get("terminal")
        if terminal is None:
            continue
        directory = output / record["path"]
        try:
            run.validate_manifest(terminal)
        except Exception as error:
            record["infrastructureErrors"].append(f"Manifest validation failed: {error}")
        try:
            NATIVE.require("expectation" in record, "Capture has no valid expectation snapshot.")
            run.validation_record = record
            recipe = record["recipe"]
            run.validate_media(terminal, recipe["mode"], "recording", [0], recipe["minimum"], recipe["maximum"],
                               static_window=record.get("staticWindow"))
        except Exception as error:
            record["mediaValidationError"] = str(error)
        finally:
            run.validation_record = None
        artifacts = [value for value in terminal.get("artifacts", []) if value.get("kind") == "recording"]
        try:
            if artifacts:
                media = Path(artifacts[-1]["path"])
                session_root = Path(run.capabilities["sessionRoot"]) / str(uuid.UUID(record["sessionID"])).upper()
                if media.is_file() and not media.is_symlink() and media.resolve().is_relative_to(session_root.resolve()):
                    GAP.command([output / "frame-gap-decode", media], directory / "decode-process.json", timeout=30)
        except (OSError, KeyError, TypeError, ValueError) as error:
            record["infrastructureErrors"].append(f"Timing decoder could not run: {error}")
        if "verifierProcess" in record:
            GAP.save(directory / "verifier-process.json", record.pop("verifierProcess"))
        GAP.save(directory / "capture.json", record)


def history_at_start(trace, anchor):
    events = (trace.get("history") or {}).get("events", [])
    alive, completed = set(), set()
    for event in sorted(events, key=lambda value: value["uptime"]):
        if event.get("uptime", math.inf) > anchor:
            continue
        writer = event.get("writerID")
        if event["name"] == "writer.init":
            alive.add(writer)
        elif event["name"] == "writer.complete":
            completed.add(writer)
        elif event["name"] == "writer.deinit":
            alive.discard(writer)
    return {"liveWriterIDs": sorted(alive), "liveCompletedWriterIDs": sorted(alive & completed)}


def analyze(output, source):
    summary = {**source, "analysisVersion": 1}
    evidence = WORKLOAD.retained_evidence(output, output / source["traceDirectory"])
    summary["retainedEvidence"] = evidence
    traces = {item["sessionID"]: item for item in evidence["traces"] if item["manifestMatched"]}
    records = []
    for planned in source["captures"]:
        record = GAP.read_json(output / planned["path"] / "capture.json") or dict(planned)
        errors = list(record.get("infrastructureErrors", []))
        completeness = []
        measured = record["role"] == "measured"
        animated = record["recipe"]["name"] != "static-window"
        trace_ref = traces.get(str(record.get("sessionID", "")).upper())
        record.update(incomingGapFailure=False, decodedGapFailure=False, mediaVerifierFailure=False)
        if trace_ref:
            trace = GAP.read_json(Path(trace_ref["path"]))
            record["writerID"] = trace.get("writerID")
            complete = [row for row in trace.get("callbacks", []) if row["screen"] and row["valid"] and row["image"]
                        and row.get("status") == 0 and row.get("pts") is not None]
            record["traceAnalysis"] = trace_ref["analysis"]
            record["incomingGapFailure"] = animated and trace_ref["analysis"]["qualityFailure"]
            record["firstToSecondPTSSeconds"] = complete[1]["pts"] - complete[0]["pts"] if len(complete) >= 2 else None
            record["firstToSecondCallbackSeconds"] = complete[1]["entryUptime"] - complete[0]["entryUptime"] if len(complete) >= 2 else None
            record["firstAppendSeconds"] = next((row["appendEnd"] - row["appendStart"] for row in complete
                                                 if row.get("appendEnd") is not None), None)
            record["writersAtStart"] = history_at_start(trace, record.get("startAcknowledgedMonotonicSeconds", 0))
            if trace.get("overflow") or trace.get("operationOverflow") or (trace.get("history") or {}).get("overflow"):
                completeness.append("Capture trace overflowed.")
            if not complete or not trace.get("history", {}).get("events"):
                completeness.append("Capture callbacks or lifecycle history are missing.")
        else:
            completeness.append("No trace joins this capture's retained manifest and recording artifact.")
        directory = output / record["path"]
        process = GAP.read_json(directory / "verifier-process.json")
        verification = GAP.process_output(process) if process else None
        expected_exit = {"passed": 0, "failed": 1}.get((verification or {}).get("status"))
        if not process or process.get("timedOut") or expected_exit is None or process.get("exitCode") != expected_exit:
            completeness.append("Media verifier did not return a consistent result.")
            if process or record.get("mediaValidationError"):
                errors.append(record.get("mediaValidationError", "Media verifier execution failed."))
        else:
            record["mediaVerifierFailure"] = verification["status"] == "failed"
            record["mediaVerification"] = verification
            if not record["mediaVerifierFailure"] and record.get("mediaValidationError"):
                errors.append(record["mediaValidationError"])
        decode_process = GAP.read_json(directory / "decode-process.json")
        decoded = GAP.process_output(decode_process) if decode_process else None
        frames = (decoded or {}).get("frames", [])
        pts = [row.get("pts") for row in frames]
        if (not decode_process or decode_process.get("exitCode") != 0 or (decoded or {}).get("status") != "passed"
                or not pts or not all(isinstance(value, (int, float)) and math.isfinite(value) for value in pts)):
            completeness.append("Timing decoder did not return a complete frame sequence.")
            if decode_process:
                errors.append("Timing decoder execution failed.")
        else:
            record["maximumDecodedInterval"] = GAP.maximum(GAP.intervals(pts))
            record["decodedGapFailure"] = bool(animated and record["maximumDecodedInterval"]
                                               and record["maximumDecodedInterval"]["seconds"] > GAP.QUALITY_GAP_SECONDS)
        if measured:
            slots = record.get("slots", [])
            record["activeStatusCount"] = sum(row.get("state") not in NATIVE.TERMINAL and "state" in row for row in slots)
            record["skippedStatusCount"] = sum(row.get("skipped", False) for row in slots)
            if len(slots) != SLOT_COUNT:
                completeness.append("Measured arm did not retain all fixed status slots.")
        record.update(infrastructureErrors=errors, completenessErrors=completeness,
                      qualityFailure=any(record[key] for key in ("incomingGapFailure", "decodedGapFailure", "mediaVerifierFailure")))
        records.append(record)
    summary["captures"] = records
    summary["pairMatching"] = []
    for pair in range(1, PAIR_COUNT + 1):
        members = [row for row in records if row["pair"] == pair]
        arms = {}
        for arm in ("cli", "direct"):
            predecessors = [row for row in members if row["arm"] == arm and row["role"] == "predecessor"]
            measured = next((row for row in members if row["arm"] == arm and row["role"] == "measured"), {})
            alive_completed = measured.get("writersAtStart", {}).get("liveCompletedWriterIDs", [])
            writer_ids = [row.get("writerID") for row in predecessors]
            arms[arm] = {"predecessorsFinalized": len(predecessors) == 3 and all((row.get("terminal") or {}).get("state") == "completed"
                          and not row["infrastructureErrors"] for row in predecessors),
                         "predecessorWritersStillAlive": len(writer_ids) == 3 and all(writer in alive_completed for writer in writer_ids),
                         "liveCompletedWriterCount": len(alive_completed), "predecessorWriterIDs": writer_ids}
        matched = all(value["predecessorsFinalized"] and value["predecessorWritersStillAlive"] for value in arms.values())
        matched = matched and arms["cli"]["liveCompletedWriterCount"] == arms["direct"]["liveCompletedWriterCount"]
        summary["pairMatching"].append({"pair": pair, "matched": matched, "arms": arms})
    summary["matchedPairCount"] = sum(row["matched"] for row in summary["pairMatching"])
    final = GAP.read_json(output / source["traceDirectory"] / "lifecycle-final.json")
    summary["finalLifecycle"] = final
    common = list(source.get("infrastructureErrors", []))
    if not final or not final.get("events") or final.get("overflow"):
        common.append("Final lifecycle history is missing or overflowed.")
    if (not evidence["fixtureDrawCount"] or not evidence["fixtureOperationCount"]
            or any(value != 0 for value in evidence["fixtureOverflow"].values()) or evidence["unmatchedTraces"]):
        common.append("Fixture chronology or artifact trace coverage is incomplete.")
    summary["commonCompletenessErrors"] = common
    summary["counts"] = {}
    for role, arm in (("predecessor", None), ("measured", "cli"), ("measured", "direct")):
        items = [row for row in records if row["role"] == role and (arm is None or row["arm"] == arm)]
        summary["counts"][arm or role] = {"planned": len(items), "started": sum("startRequestedMonotonicSeconds" in row for row in items),
            "terminal": sum(bool(row.get("terminal")) for row in items), "qualityFailures": sum(row["qualityFailure"] for row in items),
            "infrastructureFailures": sum(bool(row["infrastructureErrors"]) for row in items),
            "incomplete": sum(bool(row["completenessErrors"]) for row in items),
            "mediaVerifierFailures": sum(row["mediaVerifierFailure"] for row in items),
            "incomingGapFailures": sum(row["incomingGapFailure"] for row in items),
            "decodedGapFailures": sum(row["decodedGapFailure"] for row in items)}
    summary["status"] = "incomplete" if common or any(row["infrastructureErrors"] or row["completenessErrors"] for row in records) else "collected"
    return summary


def run_experiment(args):
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise NATIVE.Blocked("Replay requires a disposable GitHub macOS runner.")
    output = args.out.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    NATIVE.require(not any(output.iterdir()), "Replay output must be empty.")
    traces = Path(os.environ.get("SHAREX_FRAME_GAP_TRACE_DIR", str(output.with_name(output.name + "-traces")))).resolve()
    NATIVE.require(not traces.is_relative_to(output), "Trace directory must be outside the harness output.")
    traces.mkdir(parents=True, exist_ok=True)
    NATIVE.require(not any(traces.iterdir()), "Replay trace directory must be empty.")
    os.environ.update(SHAREX_FRAME_GAP_WORKLOAD="1", SHAREX_FRAME_GAP_FIXTURE_TRACE="1", SHAREX_FRAME_GAP_TRACE_DIR=str(traces))
    evidence = NATIVE.Evidence(output)
    run = ReplayRun(args, evidence)
    summary = {"diagnosticOnly": True, "pairs": PAIR_COUNT, "captures": plan(), "infrastructureErrors": [],
               "traceDirectory": os.path.relpath(traces, output), "qualityGapSeconds": GAP.QUALITY_GAP_SECONDS,
               "statusSlots": SLOT_COUNT, "statusSlotSeconds": SLOT_SECONDS, "lifecycleDrainSeconds": DRAIN_SECONDS,
               "interpretation": "Only measured status polling varies. CLI process launch and its hidden capabilities request are one bundle. "
                                 "Predecessor operations match, while their actual timings are retained. This is not an exact timing replay. "
                                 "Quality failures do not stop collection. No reproduced gap does not close the defect."}
    report = output / "replay.json"
    GAP.save(report, summary)
    handlers = {signum: signal.getsignal(signum) for signum in (signal.SIGINT, signal.SIGTERM)}
    def interrupted(signum, frame):
        raise ReplayInterrupted(f"Replay interrupted by signal {signum}.")
    for signum in handlers:
        signal.signal(signum, interrupted)
    try:
        run.preflight()
        summary["installedBinarySHA256"] = NATIVE.digest(run.binary)
        summary["appPID"] = run.app.pid
        run.command(["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-O",
                     "-target", f"{platform.machine()}-apple-macosx14.0", ROOT / "frame-gap-decode.swift",
                     "-o", output / "frame-gap-decode"], timeout=120)
        client = run.connect()
        summary["mcpPID"] = client.process.pid
        run.discover(client)
        for record in summary["captures"]:
            safe = capture(run, client, record, output)
            GAP.save(report, summary)
            print(f"Pair {record['pair']}/{PAIR_COUNT} {record['arm']} {record['recipe']['name']}: {record['status']}", flush=True)
            if not safe:
                raise NATIVE.Failure("Capture ownership could not be finalized. Remaining captures were not started.")
    except Exception as error:
        summary["infrastructureErrors"].append(str(error))
        (output / "failure.txt").write_text(traceback.format_exc(), encoding="utf-8")
    finally:
        for signum in handlers:
            signal.signal(signum, signal.SIG_IGN)
        try:
            if run.app and run.app.poll() is None and run.fixture and run.fixture.poll() is None:
                summary["drainStartedMonotonicSeconds"] = time.monotonic()
                time.sleep(DRAIN_SECONDS)
                summary["drainEndedMonotonicSeconds"] = time.monotonic()
                run.quit_app()
                summary["appQuitMonotonicSeconds"] = time.monotonic()
        except Exception as error:
            summary["infrastructureErrors"].append(f"Finalization failed: {error}")
        summary["infrastructureErrors"].extend(run.cleanup(failed=True))
        try:
            verify_captures(run, summary["captures"], output)
        except Exception as error:
            summary["infrastructureErrors"].append(f"Verification failed: {error}")
        if hasattr(run, "binary"):
            summary["binaryUnchanged"] = NATIVE.digest(run.binary) == summary.get("installedBinarySHA256")
            if not summary["binaryUnchanged"]:
                summary["infrastructureErrors"].append("Installed binary changed during replay.")
        GAP.save(output / "metrics.json", run.metrics)
        evidence.events.close()
        for signum, handler in handlers.items():
            signal.signal(signum, handler)
        GAP.save(report, summary)
    summary = analyze(output, summary)
    GAP.save(report, summary)
    print(json.dumps({"status": summary["status"], "counts": summary["counts"], "report": str(report)}, sort_keys=True))
    return 0 if summary["status"] == "collected" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--build-settings", type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--display-name")
    parser.add_argument("--reanalyze", type=Path)
    parser.add_argument("--analysis-out", type=Path)
    args = parser.parse_args()
    if args.reanalyze:
        if args.app or args.build_settings or args.out or args.display_name:
            parser.error("Offline analysis cannot be combined with capture arguments.")
        output = args.reanalyze.resolve()
        destination = args.analysis_out or output / "replay-analysis.json"
        NATIVE.require(not destination.exists(), "Analysis output already exists.")
        summary = analyze(output, GAP.read_json(output / "replay.json"))
        GAP.save(destination, summary)
        return 0 if summary["status"] == "collected" else 1
    if not all((args.app, args.build_settings, args.out)) or args.analysis_out:
        parser.error("Capture requires --app, --build-settings, and --out.")
    return run_experiment(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"Frame gap replay incomplete: {error}", file=sys.stderr)
        sys.exit(1)
