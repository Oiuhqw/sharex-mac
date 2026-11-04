#!/usr/bin/env python3
"""Validate measured work, resource ownership, and the Release hover CPU budget."""
import argparse
import json
import math
from pathlib import Path


FRAME_SAMPLES = {
    "hoverMove2x": 60,
    "regionDrag2x": 120,
    "annotRectDrag2x": 120,
    "annotPenDrag2x": 120,
    "annotHighlighterDrag2x": 120,
    "annotNewBlurDrag2x": 120,
    "annotMoveBlur2x": 120,
}
REQUIRED_STATS = {
    "overlayBuildFirstFrame2x_ms": 5,
    "annotCommitOnMouseUp2x_wall_ms": 5,
    "commitToClipboard2x_ms": 5,
    "commitMainThreadOnly2x_ms": 5,
    "commitPipelineAsync2x_ms": 5,
    "savePNG2x_ms": 5,
    "captureToOverlayShown_runner_ms": 5,
    **{f"{name}{suffix}": count for name, count in FRAME_SAMPLES.items()
       for suffix in ("_ms", "_wall_ms", "_onScreen_ms")},
}
PAIRED_FIELDS = ("legacyCPU_ms", "optimizedCPU_ms", "legacyWall_ms", "optimizedWall_ms")
CACHE_BYTES = 64 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def number(value, label, *, minimum=0, integer=False):
    require(type(value) in (int, float), f"{label} must be numeric data")
    try:
        finite = math.isfinite(value)
    except OverflowError:
        finite = False
    require(finite, f"{label} must be finite numeric data")
    require(minimum is None or value >= minimum, f"{label} is below {minimum}")
    require(not integer or int(value) == value, f"{label} must be an integer")
    return value


def object_at(parent, key):
    value = parent.get(key)
    require(isinstance(value, dict), f"{key} must be an object")
    return value


def stats(value, label, minimum):
    require(isinstance(value, dict), f"{label} must be a statistics object")
    number(value.get("n"), f"{label}.n", minimum=minimum, integer=True)
    for field in ("p50", "p95", "max", "mean"):
        number(value.get(field), f"{label}.{field}")
    require(value["p50"] <= value["p95"] <= value["max"], f"{label} quantiles are not ordered")
    require(value["mean"] <= value["max"], f"{label} mean exceeds maximum")


def validate_resources(resources):
    require(number(resources.get("schemaVersion"), "resources.schemaVersion", integer=True) == 1, "Unknown resource schema")
    number(resources.get("pid"), "resources.pid", minimum=1, integer=True)
    for field in ("rssSource", "peakSource", "cpuSource", "scope"):
        require(isinstance(resources.get(field), str) and resources[field], f"Missing resource {field}")
    scenarios = object_at(resources, "scenarios")
    for name in ("synthetic2x", "fullDisplay"):
        scenario = object_at(scenarios, name)
        allowed = ("synthetic",) if name == "synthetic2x" else ("fixture-display", "ScreenCaptureKit")
        require(scenario.get("frameSource") in allowed, f"{name} has no valid frame source")
        for key in ("baselineRSSBytes", "endRSSBytes", "lifetimePeakRSSBytes"):
            number(scenario.get(key), f"{name}.{key}", minimum=1, integer=True)
        growth = number(scenario.get("residualGrowthBytes"), f"{name}.residualGrowthBytes", minimum=None, integer=True)
        require(growth == scenario["endRSSBytes"] - scenario["baselineRSSBytes"], f"{name} residual RSS is inconsistent")
        idle = scenario.get("warmIdle")
        require(isinstance(idle, list) and len(idle) >= 5, f"{name} needs at least five idle samples")
        for sample in idle:
            require(isinstance(sample, dict), f"{name} idle sample must be an object")
            cpu = number(sample.get("cpuMS"), "idle.cpuMS")
            wall = number(sample.get("wallMS"), "idle.wallMS", minimum=500)
            percent = number(sample.get("cpuPercentOneCore"), "idle.cpuPercentOneCore")
            require(math.isclose(percent, 100 * cpu / wall, rel_tol=1e-6, abs_tol=1e-6), "Idle CPU percentage is inconsistent")
        sessions = scenario.get("sessions")
        require(isinstance(sessions, list) and len(sessions) >= 5, f"{name} needs at least five sessions")
        for index, session in enumerate(sessions):
            require(isinstance(session, dict), f"{name} session must be an object")
            require(number(session.get("index"), "session.index", integer=True) == index, f"{name} session indexes must be complete and ordered")
            for key in ("width", "height", "beforeRSSBytes", "activeRSSBytes", "afterRSSBytes", "lifetimePeakRSSBytes"):
                number(session.get(key), f"{name}.{index}.{key}", minimum=1, integer=True)
            number(session.get("scale"), "session.scale", minimum=1)
            number(session.get("cpuMS"), "session.cpuMS")
            number(session.get("wallMS"), "session.wallMS", minimum=0.001)
            for key in ("liveBytes", "liveLayerBytes"):
                require(number(session.get(key), key, minimum=1, integer=True) <= 16 * 1024 * 1024, f"{key} exceeds the live image budget")
            cache = number(session.get("cacheBytes"), "session.cacheBytes", minimum=1, integer=True)
            entries = number(session.get("cacheEntries"), "session.cacheEntries", minimum=1, integer=True)
            require(cache <= CACHE_BYTES and entries <= 128, f"{name} exceeds the effect cache budget")
            for key in ("liveBytesAfterCommit", "liveLayerBytesAfterCommit", "pointerDocumentSyncs"):
                require(number(session.get(key), key, integer=True) == 0, f"{name} retained live work after commit or synced on pointer movement")
            for key in ("outputCorrect", "budgetsPassed", "ownershipReleased", "pointerEventsVerified"):
                require(session.get(key) is True, f"{name}.{index}.{key} failed")
            peak = session["lifetimePeakRSSBytes"]
            require(peak >= max(session[key] for key in ("beforeRSSBytes", "activeRSSBytes", "afterRSSBytes")), "Session RSS exceeds lifetime peak")
        require(scenario["lifetimePeakRSSBytes"] >= max(scenario["baselineRSSBytes"], scenario["endRSSBytes"],
                *(session["lifetimePeakRSSBytes"] for session in sessions)), "Scenario RSS exceeds lifetime peak")


def validate(metrics):
    require(isinstance(metrics, dict), "Performance output must be an object")
    require(number(metrics.get("schemaVersion"), "schemaVersion", integer=True) == 1, "Unknown performance schema")
    require(number(metrics.get("errors"), "errors", integer=True) == 0, "Performance operations failed")
    require(metrics.get("frameSource") in ("sck", "fixture", "sck-window+fixture-display"), "Missing frame source")
    display = object_at(metrics, "display")
    require(display.get("px") == [3456, 2234] and display.get("scale") == 2, "Missing synthetic 2x display dimensions")
    number(display.get("runnerScale"), "display.runnerScale", minimum=1)
    for key, minimum in REQUIRED_STATS.items():
        stats(metrics.get(key), key, minimum)
    require(metrics.get("hoverVerified") is True, "Release hover events did not reach the editor")
    require(metrics["hoverMove2x_ms"]["p95"] < 2,
            "Release hoverMove2x_ms.p95 must be below 2 ms of main-thread CPU")
    correctness = object_at(metrics, "outputCorrectness")
    attempts = number(correctness.get("attemptsPerOperation"), "attemptsPerOperation", minimum=5, integer=True)
    for key, metric in (("clipboard", "commitToClipboard2x_ms"), ("savePNG", "savePNG2x_ms"),
                        ("asyncPipeline", "commitPipelineAsync2x_ms")):
        require(number(correctness.get(key), key, integer=True) == attempts == metrics[metric]["n"], f"Incomplete {key} work")
    require(metrics["commitMainThreadOnly2x_ms"]["n"] == attempts, "Incomplete main-thread pipeline work")
    paired = metrics.get("annotationRenderPaired")
    expected_cases = {f"{count}-{kind}": count for count in (10, 100, 1000) for kind in ("rectangles", "mixed")}
    require(isinstance(paired, list) and len(paired) == len(expected_cases), "Missing paired renderer cases")
    seen = set()
    for case in paired:
        require(isinstance(case, dict), "Renderer case must be an object")
        name = case.get("case")
        require(isinstance(name, str) and name in expected_cases and name not in seen, "Unknown or duplicate renderer case")
        seen.add(name)
        require(case.get("annotations") == expected_cases[name] and case.get("pixelEquivalent") is True, f"Incorrect renderer output for {name}")
        pairs = case.get("pairs")
        require(isinstance(pairs, list) and len(pairs) >= 12, f"{name} needs at least twelve pairs")
        for field in PAIRED_FIELDS:
            stats(case.get(field), f"{name}.{field}", 12)
            require(case[field]["n"] == len(pairs), f"{name} pair count does not match statistics")
        for index, pair in enumerate(pairs):
            require(isinstance(pair, dict) and pair.get("legacyFirst") is (index % 2 == 0), f"{name} must alternate pair order")
            for field in PAIRED_FIELDS:
                number(pair.get(field), f"{name}.{field}")
        for field in PAIRED_FIELDS:
            values = sorted(pair[field] for pair in pairs)
            expected = {"p50": values[int((len(values) - 1) * .5)], "p95": values[int((len(values) - 1) * .95)],
                        "max": values[-1], "mean": sum(values) / len(values)}
            require(all(math.isclose(case[field][key], value, rel_tol=1e-9, abs_tol=1e-9)
                        for key, value in expected.items()), f"{name}.{field} statistics do not match the measured pairs")
    validate_resources(object_at(metrics, "resources"))


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"Duplicate JSON field {key}")
        result[key] = value
    return result


def load(path):
    def invalid_constant(value):
        raise ValueError(f"Invalid JSON constant {value}")
    return json.loads(Path(path).read_text(encoding="utf-8"), parse_constant=invalid_constant, object_pairs_hook=unique_object)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("metrics", type=Path)
    args = parser.parse_args()
    try:
        validate(load(args.metrics))
    except (ValueError, OSError) as error:
        parser.exit(1, f"Invalid performance output: {error}\n")
    print("Validated 28 timing series, six paired renderer cases, and two resource scenarios.")


if __name__ == "__main__":
    main()
