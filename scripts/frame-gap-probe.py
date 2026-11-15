#!/usr/bin/env python3
"""Bounded, diagnostic-only paired capture. A red quality result is retained as data."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent
QUALITY_GAP_SECONDS = 0.5


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def command(arguments, path, timeout=70, env=None):
    started = time.monotonic()
    try:
        completed = subprocess.run([str(item) for item in arguments], capture_output=True,
                                   text=True, timeout=timeout, env=env, check=False)
        result = {"exitCode": completed.returncode, "stdout": completed.stdout,
                  "stderr": completed.stderr, "timedOut": False}
    except subprocess.TimeoutExpired as error:
        def text(value):
            return value.decode("utf-8", "replace") if isinstance(value, bytes) else value or ""
        result = {"exitCode": None, "stdout": text(error.stdout), "stderr": text(error.stderr), "timedOut": True}
    result.update(command=[str(item) for item in arguments], elapsedSeconds=time.monotonic() - started)
    save(path, result)
    return result


def poll(function, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = function()
        if value:
            return value
        time.sleep(0.05)
    raise RuntimeError(f"Condition did not complete within {seconds} seconds.")


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else None


def intervals(values):
    return [{"start": first, "end": second, "seconds": second - first}
            for first, second in zip(values, values[1:])]


def maximum(values):
    return max(values, key=lambda value: value["seconds"], default=None)


def summarize(report, draws):
    trace = report.get("trace") or {}
    callbacks = trace.get("callbacks", [])
    complete = [row for row in callbacks if row["screen"] and row["valid"] and row["image"]
                and row.get("status") == 0 and row.get("pts") is not None]
    pts_gaps = intervals([row["pts"] for row in complete])
    callback_gaps = intervals([row["entryUptime"] for row in callbacks])
    long_gaps = []
    for index, gap in enumerate(pts_gaps):
        if gap["seconds"] <= QUALITY_GAP_SECONDS:
            continue
        before, after = complete[index:index + 2]
        start, end = before["entryUptime"], after["entryUptime"]
        long_gaps.append({**gap, "callbackStart": start, "callbackEnd": end,
            "previousCallbackExit": before["exitUptime"],
            "drawsCompletedBetweenCallbacks": sum(start < draw["exitUptime"] < end for draw in draws),
            "heartbeatsBetweenCallbacks": sum(start < beat < end for beat in trace.get("heartbeats", [])),
            "previousSurfaceID": before.get("surfaceID"), "nextSurfaceID": after.get("surfaceID"),
            "nextRetainedSurfaceID": after.get("retainedSurfaceID")})
    limits = trace.get("limits", [])
    return {"callbackCount": len(callbacks), "completeCount": len(complete),
        "maximumPTSInterval": maximum(pts_gaps), "maximumCallbackInterval": maximum(callback_gaps),
        "maximumHeartbeatInterval": maximum(intervals(trace.get("heartbeats", []))),
        "maximumCallbackDuration": max((row["exitUptime"] - row["entryUptime"] for row in callbacks), default=0),
        "maximumAppendDuration": max((row["appendEnd"] - row["appendStart"] for row in callbacks
                                      if row.get("appendEnd") is not None), default=0),
        "maximumLimitDuration": max((row["exitUptime"] - row["entryUptime"] for row in limits), default=0),
        "writerNotReady": sum(row.get("writerReady") is False for row in callbacks),
        "uniqueSurfaceCount": len({row["surfaceID"] for row in callbacks if row.get("surfaceID") is not None}),
        "traceOverflow": trace.get("overflow"), "streamErrors": trace.get("streamErrors", []),
        "longGaps": long_gaps, "qualityFailure": bool(long_gaps)}


def process_output(process):
    try:
        result = json.loads(process["stdout"])
        return result if isinstance(result, dict) else None
    except (KeyError, TypeError, ValueError):
        return None


def artifact(path, errors):
    try:
        value = read_json(path)
    except (OSError, ValueError) as error:
        errors.append(f"Cannot read {path.name}: {error}")
        return None
    if value is None:
        errors.append(f"Missing {path.name}.")
    return value


def analyze_run(output, source, draws):
    item = {key: source[key] for key in ("fixtureMode", "pair", "variant", "path", "exitCode", "timedOut") if key in source}
    directory = output / item["path"]
    errors = []
    capture = artifact(directory / "process.json", errors)
    if capture:
        item.update(exitCode=capture.get("exitCode"), timedOut=capture.get("timedOut", False))
    if item.get("exitCode") != 0 or item.get("timedOut"):
        errors.append("Capture process failed or timed out.")
    report = artifact(directory / "trace.json", errors)
    if report:
        item["analysis"] = summarize(report, draws)
        if report.get("error"):
            item["captureError"] = report["error"]
            errors.append("Capture reported an error.")
        if item["analysis"]["traceOverflow"] or item["analysis"]["streamErrors"]:
            errors.append("Capture trace overflowed or reported a stream error.")
    item["incomingGapFailure"] = item.get("analysis", {}).get("qualityFailure", False)
    item["decodedGapFailure"] = False
    item["mediaVerifierFailure"] = False
    item["verifierExecutionFailure"] = False
    if item["variant"] == "production":
        if not (directory / "recording.mp4").is_file():
            errors.append("Production capture did not preserve a video.")
        decode = artifact(directory / "decode-process.json", errors)
        timings = process_output(decode)
        if timings is not None:
            item["decodeStatus"] = timings.get("status")
            frames = timings.get("frames")
            if not isinstance(frames, list) or not all(isinstance(row, dict) for row in frames):
                frames = []
                errors.append("Decoder result has no valid frame list.")
            item["decodedFrameCount"] = len(frames)
            pts = [row["pts"] for row in frames if isinstance(row.get("pts"), (int, float)) and math.isfinite(row["pts"])]
            if not frames or len(pts) != len(frames):
                errors.append("Decoded frames are empty or contain invalid timestamps.")
            item["maximumDecodedInterval"] = maximum(intervals(pts))
            item["decodedGapFailure"] = bool(item["maximumDecodedInterval"]
                and item["maximumDecodedInterval"]["seconds"] > QUALITY_GAP_SECONDS)
            if timings.get("error"):
                item["decodeError"] = timings["error"]
        if not decode or decode.get("timedOut") or decode.get("exitCode") != 0 or not timings or timings.get("status") != "passed":
            errors.append("Decoder failed, timed out, or did not return a valid success report.")
        verify = artifact(directory / "media-verification.json", errors)
        verification = process_output(verify)
        item["mediaVerificationExitCode"] = verify.get("exitCode") if verify else None
        if verification is not None:
            item["mediaVerification"] = verification
        expected_exit = {"passed": 0, "failed": 1}.get((verification or {}).get("status"))
        if not verify or verify.get("timedOut") or expected_exit is None or verify.get("exitCode") != expected_exit:
            item["verifierExecutionFailure"] = True
            errors.append("Media verifier failed to execute or did not return a consistent JSON result.")
        else:
            item["mediaVerifierFailure"] = verification["status"] == "failed"
    item["qualityFailure"] = any(item[key] for key in ("incomingGapFailure", "decodedGapFailure", "mediaVerifierFailure"))
    item["infrastructureErrors"] = errors
    return item


def analyze_experiment(output, source=None):
    source = source if source is not None else read_json(output / "experiment.json")
    if not isinstance(source, dict) or not isinstance(source.get("runs"), list):
        raise RuntimeError("The existing experiment report has no runs list.")
    summary = {**source, "analysisVersion": 2}
    fixture_dir = output / "fixture"
    fixture_errors = []
    draws = artifact(fixture_dir / "draw-trace.json", fixture_errors) or []
    overflow_path = fixture_dir / "draw-trace-overflow.txt"
    try:
        overflow = int(overflow_path.read_text().strip())
    except (OSError, ValueError) as error:
        overflow = None
        fixture_errors.append(f"Cannot read fixture trace overflow count: {error}")
    if not draws or overflow:
        fixture_errors.append("Fixture draw trace is empty or overflowed.")
    summary.update(fixtureDrawCount=len(draws), fixtureTraceOverflow=overflow,
                   fixtureTraceMissing=not draws or overflow is None, fixtureInfrastructureErrors=fixture_errors)
    summary["runs"] = [analyze_run(output, item, draws) for item in source["runs"]]
    for total, field in (("incomingGapFailures", "incomingGapFailure"),
                         ("decodedGapFailures", "decodedGapFailure"),
                         ("mediaVerifierFailures", "mediaVerifierFailure"),
                         ("qualityFailures", "qualityFailure"),
                         ("verifierExecutionFailures", "verifierExecutionFailure")):
        summary[total] = sum(item[field] for item in summary["runs"])
    summary["qualityFailureCountBasis"] = "Counts are captures. Category counts overlap; qualityFailures is their union. The gap bound remains 0.5 seconds."
    summary["infrastructureFailures"] = sum(bool(item["infrastructureErrors"]) for item in summary["runs"]) + bool(fixture_errors)
    summary["status"] = "collected" if not summary["infrastructureFailures"] else "incomplete"
    return summary


def reanalyze(directory, destination=None):
    directory = directory.resolve()
    destination = destination.resolve() if destination else directory / "analysis-v2.json"
    if destination.exists():
        raise RuntimeError(f"Analysis output already exists; choose a new --analysis-out path: {destination}")
    summary = analyze_experiment(directory)
    summary["sourceExperimentSHA256"] = hashlib.sha256((directory / "experiment.json").read_bytes()).hexdigest()
    save(destination, summary)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["status"] == "collected" else 1


def run(args):
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("This probe requires a disposable GitHub macOS runner.")
    if not 5 <= args.pairs <= 12:
        raise RuntimeError("Use 5 through 12 matched pairs.")
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=False)
    binary = args.app.resolve() / "Contents/MacOS/ShareX"
    summary = {"diagnosticOnly": True, "pairsPerMode": args.pairs, "fixtureModes": args.fixture_modes, "runs": [],
        "captureSecondsAfterFirstFrame": 6, "qualityGapSeconds": QUALITY_GAP_SECONDS,
        "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "interpretation": "Fixture draw chronology does not prove compositor presentation. "
                          "Metadata gaps show the writer is unnecessary for reproduction. "
                          "Recorder-only gaps implicate consumer workload or retention but do not select a fix. "
                          "No gaps in either arm is inconclusive, not a closed defect."}
    save(output / "experiment.json", summary)
    for source in ("agent-capture-fixture", "frame-gap-decode", "verify-agent-media"):
        build = command(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-O",
                         "-target", f"{platform.machine()}-apple-macosx14.0", ROOT / f"{source}.swift",
                         "-o", output / source], output / f"build-{source}.json", timeout=120)
        if build["exitCode"] != 0:
            raise RuntimeError(f"Could not build {source}; see saved build output.")
    fixture_dir = output / "fixture"
    fixture_dir.mkdir()
    title = "ShareX frame gap probe " + str(uuid.uuid4())
    env = {**os.environ, "SHAREX_FRAME_GAP_FIXTURE_TRACE": "1"}
    with (output / "fixture.log").open("w", encoding="utf-8") as log:
        fixture = subprocess.Popen([str(output / "agent-capture-fixture"), str(fixture_dir), title],
                                   stdout=log, stderr=subprocess.STDOUT, env=env)
        try:
            def state():
                if fixture.poll() is not None:
                    raise RuntimeError("Fixture exited before capture finished.")
                return read_json(fixture_dir / "state.json")

            ready = poll(lambda: (value if (value := state()) and value.get("draws", 0) >= 10 else None), 15)
            if ready.get("status") != "ready":
                raise RuntimeError(f"Fixture unavailable: {ready}")
            for mode in args.fixture_modes:
                noise_id = str(uuid.uuid4())
                save(fixture_dir / "command.json", {"id": noise_id, "action": "noise", "enabled": mode == "noisy"})
                poll(lambda: (value if (value := state()) and value.get("commandID") == noise_id else None), 5)
                for pair in range(1, args.pairs + 1):
                    order = ("production", "metadata") if pair % 2 else ("metadata", "production")
                    for variant in order:
                        directory = output / f"{mode}-pair-{pair:02d}-{variant}"
                        directory.mkdir()
                        before = state()
                        result = command([binary, "--frame-gap-probe", variant, title, directory], directory / "process.json")
                        after = state()
                        save(directory / "fixture-boundaries.json", {"before": before, "after": after})
                        summary["runs"].append({"fixtureMode": mode, "pair": pair, "variant": variant, "path": directory.name,
                                                "exitCode": result["exitCode"], "timedOut": result["timedOut"]})
                        save(output / "experiment.json", summary)
                        print(f"{mode} pair {pair}/{args.pairs} {variant}: exit={result['exitCode']}", flush=True)
                        time.sleep(0.5)
        finally:
            if fixture.poll() is None:
                save(fixture_dir / "command.json", {"id": str(uuid.uuid4()), "action": "quit"})
                try:
                    fixture.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    fixture.kill()
                    fixture.wait(timeout=5)
    expectation = {"width": 640, "height": 480, "fps": 15, "motion": "animated", "stages": [0],
        "minimumDuration": 5.5, "maximumDuration": 8,
        "anchors": [{"x": x, "y": y, "rgb": rgb} for x, y, rgb in
                    ((.3, .3, [230, 32, 40]), (.7, .3, [32, 210, 80]),
                     (.3, .7, [30, 80, 230]), (.7, .7, [240, 210, 40]))],
        "marker": {"x": .5, "y": .5, "rgb": [0, 255, 255]}}
    save(output / "expectation.json", expectation)
    for item in summary["runs"]:
        directory = output / item["path"]
        video = directory / "recording.mp4"
        if video.exists():
            decode = command([output / "frame-gap-decode", video], directory / "decode-process.json", timeout=30)
            timings = process_output(decode)
            if timings is not None:
                save(directory / "decoded-frames.json", timings)
            command([output / "verify-agent-media", video, output / "expectation.json"],
                    directory / "media-verification.json", timeout=30)
    summary = analyze_experiment(output, summary)
    for item in summary["runs"]:
        save(output / item["path"] / "analysis.json", item)
    save(output / "experiment.json", summary)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["status"] == "collected" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--reanalyze", type=Path, help="Analyze an existing experiment folder without capture or native tools.")
    parser.add_argument("--analysis-out", type=Path, help="New report path; defaults to EXISTING_FOLDER/analysis-v2.json.")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--fixture-modes", nargs="+", choices=("noisy", "animated"), default=["noisy", "animated"])
    try:
        args = parser.parse_args()
        if args.reanalyze:
            if args.app or args.out:
                parser.error("--reanalyze cannot be combined with --app or --out.")
            sys.exit(reanalyze(args.reanalyze, args.analysis_out))
        if not args.app or not args.out or args.analysis_out:
            parser.error("Capture requires --app and --out; --analysis-out requires --reanalyze.")
        sys.exit(run(args))
    except Exception as error:
        print(f"Frame gap probe incomplete: {error}", file=sys.stderr)
        sys.exit(1)
