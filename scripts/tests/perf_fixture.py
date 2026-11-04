import copy


def measured_stats(count, value=1.25):
    return {"n": count, "p50": value, "p95": value, "max": value, "mean": value}


def good_metrics():
    metrics = {
        "schemaVersion": 1, "errors": 0, "frameSource": "sck-window+fixture-display",
        "display": {"px": [3456, 2234], "scale": 2, "runnerScale": 1},
        "outputCorrectness": {"attemptsPerOperation": 5, "clipboard": 5, "savePNG": 5, "asyncPipeline": 5},
    }
    for name in ("overlayBuildFirstFrame2x_ms", "annotCommitOnMouseUp2x_wall_ms", "commitToClipboard2x_ms",
                 "commitMainThreadOnly2x_ms", "commitPipelineAsync2x_ms", "savePNG2x_ms", "captureToOverlayShown_runner_ms"):
        metrics[name] = measured_stats(5)
    for name in ("hoverMove2x", "regionDrag2x", "annotRectDrag2x", "annotPenDrag2x", "annotHighlighterDrag2x",
                 "annotNewBlurDrag2x", "annotMoveBlur2x"):
        for suffix in ("_ms", "_wall_ms", "_onScreen_ms"):
            metrics[name + suffix] = measured_stats(60 if name == "hoverMove2x" else 120)
    fields = ("legacyCPU_ms", "optimizedCPU_ms", "legacyWall_ms", "optimizedWall_ms")
    metrics["annotationRenderPaired"] = [
        {"case": f"{count}-{kind}", "annotations": count, "pixelEquivalent": True,
         **{field: measured_stats(12) for field in fields},
         "pairs": [{"legacyFirst": index % 2 == 0, **{field: 1.25 for field in fields}} for index in range(12)]}
        for count in (10, 100, 1000) for kind in ("rectangles", "mixed")
    ]
    scenario = {
        "warmIdle": [{"cpuMS": .5, "wallMS": 500.5, "cpuPercentOneCore": 100 * .5 / 500.5} for _ in range(5)],
        "baselineRSSBytes": 50_000_000, "endRSSBytes": 60_000_000, "residualGrowthBytes": 10_000_000,
        "lifetimePeakRSSBytes": 120_000_000,
        "sessions": [{"index": index, "width": 3456, "height": 2234, "scale": 2,
                      "beforeRSSBytes": 50_000_000, "activeRSSBytes": 100_000_000, "afterRSSBytes": 60_000_000,
                      "lifetimePeakRSSBytes": 120_000_000, "cpuMS": 60.25, "wallMS": 100.5,
                      "cacheBytes": 8_000_000, "cacheEntries": 1, "liveBytes": 8_000_000,
                      "liveLayerBytes": 8_000_000, "liveBytesAfterCommit": 0, "liveLayerBytesAfterCommit": 0,
                      "pointerDocumentSyncs": 0, "pointerEventsVerified": True,
                      "outputCorrect": True, "budgetsPassed": True, "ownershipReleased": True} for index in range(5)],
    }
    metrics["resources"] = {
        "schemaVersion": 1, "pid": 123, "rssSource": "proc_pidinfo(PROC_PIDTASKINFO).pti_resident_size",
        "peakSource": "getrusage.ru_maxrss (macOS bytes, process lifetime)",
        "cpuSource": "getrusage user+system CPU; percent is relative to one core",
        "scope": "App process only; excludes WindowServer/GPU memory and CPU.",
        "scenarios": {name: {**copy.deepcopy(scenario), "frameSource": source}
                      for name, source in (("synthetic2x", "synthetic"), ("fullDisplay", "fixture-display"))},
    }
    return metrics
