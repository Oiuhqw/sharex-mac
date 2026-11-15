from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import test_frame_gap_startup as BASE

REQUEST, STARTUP = BASE.REQUEST, BASE.STARTUP


class WriterLifetimeTests(unittest.TestCase):
    def evidence(self, root, condition="release", gap=False):
        trace, _, _ = BASE.AnalysisTests().bitmap_evidence(root, "original")
        trace["context"].update(writerLifetime=condition, fps=15, queueDepth=3)
        events = []
        for index in range(7):
            identity = f"writer-{index}"
            events.extend([{"name": "writer.init", "writerID": identity, "uptime": index + 1,
                            "writerLifetime": condition},
                           {"name": "writer.complete", "writerID": identity, "uptime": index + 1.1}])
            if condition == "release" or index == 0:
                events.append({"name": "writer.deinit", "writerID": identity, "uptime": index + 1.2})
        trace["history"]["events"] = events
        template = trace["callbacks"][0]
        trace["callbacks"] = [{**template, "pts": pts, "ptsValue": round(pts * 1e9),
                               "ptsTimescale": 1000000000, "ptsFlags": 1, "ptsEpoch": 0,
                               "displayTime": round(pts * 1e9), "sourcePixelFormat": 1111970369,
                               "entryUptime": pts + 0.001, "exitUptime": pts + 0.002}
                              for pts in (10 + index / 15 for index in range(45))
                              if not gap or pts == 10 or pts >= 10.6]
        STARTUP.GAP.save(root / "traces/target-trace.json", trace)
        for index in range(7):
            STARTUP.GAP.save(root / f"traces/prior-{index}-trace.json",
                             {**trace, "writerID": f"writer-{index}", "context": {"writerLifetime": condition}})
        result_path = root / "native/result.json"
        STARTUP.GAP.save(result_path, {**STARTUP.GAP.read_json(result_path), "writerLifetime": condition,
                                       "requestedWriterLifetime": condition, "productionE2EPassed": False})
        STARTUP.GAP.save(root / "native/fixture/operation-trace.json", [
            {"name": "stateWrite", "phase": "begin", "uptime": 10.1},
            {"name": "stateWrite", "phase": "end", "uptime": 10.101}])
        return trace

    def analyze(self, root, condition):
        return STARTUP.analyze_arm(root, "metadata", REQUEST, "before", "original", "cgimage", condition)

    def test_delivered_release_keeps_the_raw_gap_and_seven_deinit_entries(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.evidence(root, gap=True)
            result = self.analyze(root, "release")
            self.assertEqual(result["errors"], [])
            lifecycle = result["writerLifecycle"]
            self.assertEqual(len(lifecycle["writers"]), 7)
            self.assertEqual(lifecycle["atTargetStart"]["count"], 0)
            gap = lifecycle["allSourceGaps"][0]
            self.assertAlmostEqual(gap["seconds"], 0.6)
            self.assertTrue(gap["rawTimelineReviewRequired"])
            self.assertTrue(gap["ownershipAbsentAtGapStart"])
            self.assertFalse(gap["retentionThroughoutGap"])
            self.assertTrue(all(value["writerIDs"] == [] for value in gap["liveCompletedWriters"].values()))
            self.assertFalse(result["result"]["productionE2EPassed"])

    def test_retain_reports_observed_ids_and_lifetime_at_both_clock_boundaries(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            trace = self.evidence(root, "retain", gap=True)
            trace["history"]["events"].extend({"name": "writer.deinit", "writerID": f"writer-{index}",
                                              "uptime": 10.0005} for index in range(1, 7))
            STARTUP.GAP.save(root / "traces/target-trace.json", trace)
            result = self.analyze(root, "retain")
            self.assertEqual(result["errors"], [])
            lifecycle = result["writerLifecycle"]
            self.assertEqual(lifecycle["atTargetStart"]["writerIDs"], [f"writer-{index}" for index in range(1, 7)])
            gap = lifecycle["allSourceGaps"][0]
            self.assertEqual(gap["liveCompletedWriters"]["sourceStart"]["count"], 6)
            self.assertEqual(gap["liveCompletedWriters"]["callbackStart"]["count"], 0)
            self.assertFalse(gap["retentionThroughoutGap"])

    def test_missing_duplicate_late_or_wrong_identity_history_is_incomplete(self):
        cases = {
            "missing deinit": lambda trace: trace["history"]["events"].pop(),
            "missing complete": lambda trace: trace["history"]["events"].pop(-2),
            "duplicate complete": lambda trace: trace["history"]["events"].append(trace["history"]["events"][-2]),
            "unknown complete": lambda trace: trace["history"]["events"][-2].update(writerID="other"),
            "missing identity": lambda trace: trace["history"]["events"][0].pop("writerID"),
            "late complete": lambda trace: trace["history"]["events"][-2].update(uptime=10),
            "late deinit": lambda trace: trace["history"]["events"][-1].update(uptime=10),
            "overflow": lambda trace: trace["history"].update(overflow=1),
            "wrong mode": lambda trace: trace["history"]["events"][0].update(writerLifetime="retain"),
            "wrong target mode": lambda trace: trace["context"].update(writerLifetime="retain"),
        }
        for name, mutate in cases.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                trace = self.evidence(root)
                mutate(trace)
                STARTUP.GAP.save(root / "traces/target-trace.json", trace)
                self.assertTrue(self.analyze(root, "release")["errors"])

    def test_no_live_retain_control_and_wrong_prior_trace_identity_are_incomplete(self):
        for fault in ("no live control", "wrong prior identity", "wrong prior mode", "wrong result mode"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                trace = self.evidence(root, "retain")
                if fault == "no live control":
                    trace["history"]["events"].extend({"name": "writer.deinit", "writerID": f"writer-{index}",
                                                      "uptime": 9} for index in range(1, 7))
                    STARTUP.GAP.save(root / "traces/target-trace.json", trace)
                else:
                    path = root / ("native/result.json" if fault == "wrong result mode" else "traces/prior-1-trace.json")
                    value = STARTUP.GAP.read_json(path)
                    if fault == "wrong prior identity":
                        value["writerID"] = "writer-0"
                    elif fault == "wrong prior mode":
                        value["context"]["writerLifetime"] = "release"
                    else:
                        value["writerLifetime"] = "release"
                    STARTUP.GAP.save(path, value)
                self.assertTrue(self.analyze(root, "retain")["errors"])

    def test_intervening_callback_invalid_raw_pts_and_changed_source_are_incomplete(self):
        for fault in ("intervening callback", "raw pts", "source config"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                trace = self.evidence(root, gap=True)
                if fault == "intervening callback":
                    trace["callbacks"].insert(1, {**trace["callbacks"][0], "pts": None,
                                                  "entryUptime": 10.3, "exitUptime": 10.301, "status": 1})
                elif fault == "raw pts":
                    trace["callbacks"][0]["ptsValue"] = 0
                else:
                    trace["context"]["queueDepth"] = 5
                STARTUP.GAP.save(root / "traces/target-trace.json", trace)
                self.assertTrue(self.analyze(root, "release")["errors"])

    def test_actual_condition_parser_rejects_missing_wrong_and_foreign_modes(self):
        base = ["startup", "--app", "/app", "--build-settings", "/settings", "--out", "/out",
                "--comparison", "writer-lifetime", "--arm", "metadata", "--noise-timing", "before",
                "--bitmap-content", "original"]
        for condition in ("retain", "release"):
            for requested in (None, "retain", "release", "other"):
                with self.subTest(condition=condition, requested=requested), \
                     mock.patch.object(STARTUP.sys, "argv", base + (["--writer-lifetime", requested] if requested else [])), \
                     mock.patch.dict(STARTUP.os.environ, {"SHAREX_FRAME_GAP_WRITER_LIFETIME": condition}), \
                     mock.patch.object(STARTUP, "run_arm", return_value=0), mock.patch.object(STARTUP.sys, "stderr"):
                    if requested == condition:
                        self.assertEqual(STARTUP.main(), 0)
                    else:
                        with self.assertRaises(SystemExit):
                            STARTUP.main()

    def test_fixed_eight_arms_preserve_outputs_continue_after_failure_and_skip_pixel_check(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "ShareX.app"
            binary = app / "Contents/MacOS/ShareX"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"fixed diagnostic app")
            setup = root / "setup.json"
            STARTUP.GAP.save(setup, {"status": "passed"})
            args = SimpleNamespace(out=root / "comparison", app=app, build_settings=root / "settings.json",
                                   setup_result=setup, commit="diagnostic-revision", comparison="writer-lifetime")
            calls = []

            def harness(arguments, log, environment, timeout):
                with mock.patch.object(STARTUP.sys, "argv", [str(part) for part in arguments[1:]]), \
                     mock.patch.dict(STARTUP.os.environ, environment), \
                     mock.patch.object(STARTUP, "run_arm", side_effect=lambda parsed: calls.append((parsed, timeout)) or 0):
                    self.assertEqual(STARTUP.main(), 0)
                parsed = calls[-1][0]
                (log.parent / "traces").rmdir()
                trace = self.evidence(log.parent, parsed.writer_lifetime, gap=parsed.writer_lifetime == "retain")
                if len(calls) == 2:
                    trace["history"]["events"].pop()
                    STARTUP.GAP.save(log.parent / "traces/target-trace.json", trace)
                for path in log.parent.rglob("*"):
                    if path.suffix in (".json", ".jsonl"):
                        path.write_text(path.read_text().replace(REQUEST, environment["SHAREX_FRAME_GAP_STARTUP_REQUEST_ID"]))
                return {"exitCode": 0, "timedOut": False}

            with mock.patch.object(STARTUP.sys, "platform", "darwin"), \
                 mock.patch.dict(STARTUP.os.environ, {"GITHUB_ACTIONS": "true"}), \
                 mock.patch.object(STARTUP.WORKLOAD, "bounded_harness", side_effect=harness), \
                 mock.patch.object(STARTUP, "compare_black_pixels") as pixels, mock.patch("builtins.print"):
                self.assertEqual(STARTUP.run_comparison(args), 1)
            report = STARTUP.GAP.read_json(args.out / "comparison.json")
            self.assertEqual(report["order"], list(STARTUP.WRITER_LIFETIME_ORDER))
            self.assertEqual([parsed.writer_lifetime for parsed, _ in calls], report["order"])
            self.assertEqual([timeout for _, timeout in calls], [240] * 8)
            self.assertEqual(len({run["requestID"] for run in report["runs"]}), 8)
            self.assertEqual(report["incompleteArms"], 1)
            self.assertEqual(report["outcome"], "collection_incomplete_requires_independent_classification")
            self.assertFalse(report["productionE2EPassed"])
            pixels.assert_not_called()
            for run in report["runs"]:
                self.assertEqual(run["bitmapContent"], "original")
                self.assertEqual(run["noiseTiming"], "before")
                self.assertEqual(run["arm"], "metadata")
                self.assertTrue(Path(run["trace"]).exists())

    def test_write_durations_are_retained_without_an_automatic_causal_cutoff(self):
        for duration in (0.001, 0.4, 0.58):
            with self.subTest(duration=duration), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.evidence(root, gap=True)
                STARTUP.GAP.save(root / "native/fixture/operation-trace.json", [
                    {"name": "stateWrite", "phase": "begin", "uptime": 10.01},
                    {"name": "stateWrite", "phase": "end", "uptime": 10.01 + duration}])
                result = self.analyze(root, "release")
                self.assertEqual(result["errors"], [])
                gap = result["writerLifecycle"]["allSourceGaps"][0]
                self.assertAlmostEqual(gap["fixtureWriteSpans"][0]["seconds"], duration)
                self.assertTrue(gap["rawTimelineReviewRequired"])
                self.assertNotIn("qualifiedResidualGap", gap)

    def test_unmatched_shutdown_update_is_retained_but_target_overlap_is_incomplete(self):
        for uptime in (10.2, 13.1):
            with self.subTest(uptime=uptime), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.evidence(root)
                path = root / "native/fixture/operation-trace.json"
                operations = STARTUP.GAP.read_json(path)
                operations.append({"name": "update", "phase": "begin", "uptime": uptime})
                STARTUP.GAP.save(path, operations)
                result = self.analyze(root, "release")
                self.assertEqual(bool(result["errors"]), uptime == 10.2)
                self.assertEqual(result["writerLifecycle"]["unmatchedFixtureOperations"], {"update": uptime})


if __name__ == "__main__":
    unittest.main()
