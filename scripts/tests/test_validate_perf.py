import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from perf_fixture import good_metrics, measured_stats


SCRIPT = Path(__file__).resolve().parents[1] / "validate-perf.py"
SPEC = importlib.util.spec_from_file_location("validate_perf", SCRIPT)
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)


class ValidatePerfTests(unittest.TestCase):
    def test_release_hover_cpu_budget(self):
        for cpu, accepted in ((1.999, True), (2.0, False), (2.001, False)):
            metrics = good_metrics()
            metrics["hoverMove2x_ms"] = measured_stats(60, cpu)
            with self.subTest(cpu=cpu):
                if accepted:
                    validator.validate(metrics)
                else:
                    with self.assertRaisesRegex(ValueError, "hoverMove2x_ms.p95.*2 ms.*CPU"):
                        validator.validate(metrics)

    def test_wall_and_display_callback_costs_are_diagnostics(self):
        metrics = good_metrics()
        metrics["hoverMove2x_wall_ms"] = measured_stats(60, 8)
        metrics["hoverMove2x_onScreen_ms"] = measured_stats(60, 40)
        validator.validate(metrics)

    def test_hover_event_delivery_is_required(self):
        for value in (False, None, 1, "true"):
            metrics = good_metrics()
            metrics["hoverVerified"] = value
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "hover events"):
                validator.validate(metrics)

    def test_complete_native_shaped_metrics_pass(self):
        validator.validate(good_metrics())

    def test_every_required_metric_must_be_present(self):
        for key in good_metrics():
            with self.subTest(key=key):
                metrics = good_metrics()
                del metrics[key]
                with self.assertRaises(ValueError):
                    validator.validate(metrics)

    def test_empty_sparse_or_wrong_top_level_fails(self):
        for metrics in (None, [], {}, {"display": {"scale": 2}}, {"schemaVersion": 1}):
            with self.subTest(metrics=metrics), self.assertRaises(ValueError):
                validator.validate(metrics)

    def test_invalid_sample_counts_fail(self):
        for count in (0, -1, 4, 5.5, True, "5", float("nan"), float("inf")):
            metrics = good_metrics()
            metrics["commitToClipboard2x_ms"]["n"] = count
            with self.subTest(count=count), self.assertRaises(ValueError):
                validator.validate(metrics)

    def test_invalid_statistics_fail(self):
        for field in ("p50", "p95", "max", "mean"):
            for value in (-1, float("nan"), float("inf"), True, "1", None, 10**500):
                metrics = good_metrics()
                metrics["hoverMove2x_ms"][field] = value
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    validator.validate(metrics)
        for field in ("p50", "p95", "mean"):
            metrics = good_metrics()
            metrics["hoverMove2x_ms"][field] = 20
            with self.subTest(field=field), self.assertRaises(ValueError):
                validator.validate(metrics)

    def test_failed_or_incomplete_outputs_fail(self):
        for field in ("clipboard", "savePNG", "asyncPipeline", "attemptsPerOperation"):
            metrics = good_metrics()
            metrics["outputCorrectness"][field] = 4
            with self.subTest(field=field), self.assertRaises(ValueError):
                validator.validate(metrics)
        metrics = good_metrics()
        metrics["errors"] = 1
        with self.assertRaises(ValueError):
            validator.validate(metrics)

    def test_missing_or_false_paired_results_fail(self):
        for field, value in (("pixelEquivalent", False), ("annotations", 0), ("pairs", []), ("case", "unknown")):
            metrics = good_metrics()
            metrics["annotationRenderPaired"][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validator.validate(metrics)
        metrics = good_metrics()
        metrics["annotationRenderPaired"][1] = copy.deepcopy(metrics["annotationRenderPaired"][0])
        with self.assertRaises(ValueError):
            validator.validate(metrics)

    def test_paired_summaries_must_match_raw_measurements(self):
        metrics = good_metrics()
        metrics["annotationRenderPaired"][0]["pairs"][0]["legacyCPU_ms"] = 4
        with self.assertRaises(ValueError):
            validator.validate(metrics)

    def test_resource_failures_and_retained_work_fail(self):
        bad = {"cacheBytes": 64 * 1024 * 1024 + 1, "cacheEntries": 129, "liveBytesAfterCommit": 1,
               "liveLayerBytesAfterCommit": 1, "liveBytes": 16 * 1024 * 1024 + 1,
               "liveLayerBytes": 16 * 1024 * 1024 + 1,
               "pointerDocumentSyncs": 1, "pointerEventsVerified": False, "outputCorrect": False, "budgetsPassed": False,
               "ownershipReleased": False, "activeRSSBytes": 0, "cpuMS": -1, "wallMS": 0,
               "lifetimePeakRSSBytes": 1, "index": 10}
        for key, value in bad.items():
            metrics = good_metrics()
            metrics["resources"]["scenarios"]["synthetic2x"]["sessions"][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                validator.validate(metrics)

    def test_resource_completeness_and_idle_measurements_fail_closed(self):
        for key, value in (("sessions", []), ("warmIdle", []), ("residualGrowthBytes", 1), ("frameSource", "unknown")):
            metrics = good_metrics()
            metrics["resources"]["scenarios"]["fullDisplay"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                validator.validate(metrics)
        metrics = good_metrics()
        metrics["resources"]["scenarios"]["fullDisplay"]["warmIdle"][0]["cpuPercentOneCore"] = 9
        with self.assertRaises(ValueError):
            validator.validate(metrics)

    def test_live_preview_must_exist_before_release(self):
        for key in ("liveBytes", "liveLayerBytes"):
            metrics = good_metrics()
            metrics["resources"]["scenarios"]["synthetic2x"]["sessions"][0][key] = 0
            with self.subTest(key=key), self.assertRaises(ValueError):
                validator.validate(metrics)

    def test_rss_recovery_and_zero_idle_cpu_are_valid(self):
        metrics = good_metrics()
        scenario = metrics["resources"]["scenarios"]["fullDisplay"]
        scenario["endRSSBytes"] = 40_000_000
        scenario["residualGrowthBytes"] = -10_000_000
        scenario["warmIdle"][0].update(cpuMS=0, cpuPercentOneCore=0)
        validator.validate(metrics)

    def test_cli_reports_corrupt_or_nonstandard_json_as_failure(self):
        for content in ("{", "null", "{}", '{"schemaVersion":1,"schemaVersion":1}', '{"errors":NaN}', '{"errors":Infinity}'):
            with self.subTest(content=content), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "perf.json"
                path.write_text(content, encoding="utf-8")
                result = subprocess.run([sys.executable, str(SCRIPT), str(path)], capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Invalid performance output", result.stderr)

    def test_cli_accepts_complete_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "perf.json"
            path.write_text(json.dumps(good_metrics()), encoding="utf-8")
            result = subprocess.run([sys.executable, str(SCRIPT), str(path)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
