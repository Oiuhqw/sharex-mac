#!/usr/bin/env python3
"""Bounded, diagnostic-only paired capture. A red quality result is retained as data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent


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
        if gap["seconds"] <= 0.5:
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


def run(args):
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("This probe requires a disposable GitHub macOS runner.")
    if not 5 <= args.pairs <= 12:
        raise RuntimeError("Use 5 through 12 matched pairs.")
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=False)
    binary = args.app.resolve() / "Contents/MacOS/ShareX"
    summary = {"diagnosticOnly": True, "pairsPerMode": args.pairs, "fixtureModes": args.fixture_modes, "runs": [],
        "captureSecondsAfterFirstFrame": 6, "qualityGapSeconds": 0.5,
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
    draws = read_json(fixture_dir / "draw-trace.json") or []
    summary["fixtureDrawCount"] = len(draws)
    overflow_path = fixture_dir / "draw-trace-overflow.txt"
    summary["fixtureTraceOverflow"] = int(overflow_path.read_text().strip()) if overflow_path.exists() else None
    summary["fixtureTraceMissing"] = not draws or not overflow_path.exists()
    expectation = {"width": 640, "height": 480, "fps": 15, "motion": "animated", "stages": [0],
        "minimumDuration": 5.5, "maximumDuration": 8,
        "anchors": [{"x": x, "y": y, "rgb": rgb} for x, y, rgb in
                    ((.3, .3, [230, 32, 40]), (.7, .3, [32, 210, 80]),
                     (.3, .7, [30, 80, 230]), (.7, .7, [240, 210, 40]))],
        "marker": {"x": .5, "y": .5, "rgb": [0, 255, 255]}}
    save(output / "expectation.json", expectation)
    for item in summary["runs"]:
        directory = output / item["path"]
        report = read_json(directory / "trace.json")
        if report is None:
            item["infrastructureError"] = "Capture did not produce a trace."
            continue
        item["analysis"] = summarize(report, draws)
        if report.get("error"):
            item["captureError"] = report["error"]
        video = directory / "recording.mp4"
        if video.exists():
            decode = command([output / "frame-gap-decode", video], directory / "decode-process.json", timeout=30)
            try:
                timings = json.loads(decode["stdout"])
                save(directory / "decoded-frames.json", timings)
                item["decodeStatus"] = timings["status"]
                if timings.get("error"):
                    item["decodeError"] = timings["error"]
                item["decodedFrameCount"] = len(timings["frames"])
                item["maximumDecodedInterval"] = maximum(intervals([row["pts"] for row in timings["frames"] if "pts" in row]))
            except (ValueError, KeyError) as error:
                item["decodeError"] = str(error)
            verify = command([output / "verify-agent-media", video, output / "expectation.json"],
                             directory / "media-verification.json", timeout=30)
            item["mediaVerificationExitCode"] = verify["exitCode"]
            try:
                item["mediaVerification"] = json.loads(verify["stdout"])
            except ValueError:
                item["infrastructureError"] = "Media verifier did not return a JSON result."
        elif item["variant"] == "production":
            item["infrastructureError"] = "Production capture did not preserve a video."
        save(directory / "analysis.json", item)
    summary["qualityFailures"] = sum(item.get("analysis", {}).get("qualityFailure", False) for item in summary["runs"])
    summary["infrastructureFailures"] = sum(item.get("exitCode") != 0 or "infrastructureError" in item
                                           or "captureError" in item or "decodeError" in item
                                           or bool(item.get("analysis", {}).get("streamErrors"))
                                           or bool(item.get("analysis", {}).get("traceOverflow"))
                                           for item in summary["runs"])
    if summary["fixtureTraceMissing"] or summary["fixtureTraceOverflow"]:
        summary["infrastructureFailures"] += 1
    summary["status"] = "collected" if not summary["infrastructureFailures"] else "incomplete"
    save(output / "experiment.json", summary)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["status"] == "collected" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--fixture-modes", nargs="+", choices=("noisy", "animated"), default=["noisy", "animated"])
    try:
        sys.exit(run(parser.parse_args()))
    except Exception as error:
        print(f"Frame gap probe incomplete: {error}", file=sys.stderr)
        sys.exit(1)
