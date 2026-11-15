import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "frame-gap-probe.py"
SPEC = importlib.util.spec_from_file_location("frame_gap_probe", SCRIPT)
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class OfflineFrameGapTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.output = Path(self.temporary.name)
        fixture = self.output / "fixture"
        fixture.mkdir()
        PROBE.save(fixture / "draw-trace.json", [{"exitUptime": 10.2}])
        (fixture / "draw-trace-overflow.txt").write_text("0\n")
        self.source = {"runs": [], "qualityFailures": 0, "infrastructureFailures": 0}

    def add_run(self, name, incoming=.1, decoded=.1, verification="passed", verify_exit=None, variant="production"):
        directory = self.output / name
        directory.mkdir()
        item = {"path": name, "variant": variant, "fixtureMode": "noisy", "pair": len(self.source["runs"]) + 1,
                "exitCode": 0, "timedOut": False}
        self.source["runs"].append(item)
        PROBE.save(directory / "process.json", {"exitCode": 0, "timedOut": False})
        callbacks = [{"screen": True, "valid": True, "image": True, "status": 0, "pts": pts,
                      "entryUptime": 10 + pts, "exitUptime": 10 + pts + .001}
                     for pts in (0, incoming)]
        PROBE.save(directory / "trace.json", {"trace": {"callbacks": callbacks, "limits": [],
                   "heartbeats": [], "overflow": 0, "streamErrors": []}})
        if variant == "production":
            (directory / "recording.mp4").write_bytes(b"Original video fixture; never execute native tools.")
            PROBE.save(directory / "decode-process.json", {"exitCode": 0, "timedOut": False,
                       "stdout": json.dumps({"status": "passed", "frames": [{"pts": 0}, {"pts": decoded}]})})
            PROBE.save(directory / "media-verification.json", {"exitCode": (0 if verification == "passed" else 1)
                       if verify_exit is None else verify_exit, "timedOut": False,
                       "stdout": json.dumps({"status": verification, "reason": "Saved native result."})})
        PROBE.save(self.output / "experiment.json", self.source)
        return directory

    def test_distinct_and_overlapping_failures_count_once_in_union(self):
        self.add_run("incoming-only", incoming=.6)
        self.add_run("decoded-only", decoded=.6)
        self.add_run("verifier-only", verification="failed")
        self.add_run("all-three", incoming=.7, decoded=.7, verification="failed")
        result = PROBE.analyze_experiment(self.output)
        self.assertEqual((result["incomingGapFailures"], result["decodedGapFailures"], result["mediaVerifierFailures"]), (2, 2, 2))
        self.assertEqual(result["qualityFailures"], 4)
        self.assertEqual(result["infrastructureFailures"], 0)
        self.assertEqual(result["status"], "collected")

    def test_verifier_execution_failure_is_not_a_quality_rejection(self):
        self.add_run("bad-exit", verification="failed", verify_exit=2)
        result = PROBE.analyze_experiment(self.output)
        self.assertEqual(result["qualityFailures"], 0)
        self.assertEqual(result["verifierExecutionFailures"], 1)
        self.assertEqual(result["infrastructureFailures"], 1)
        self.assertEqual(result["status"], "incomplete")

    def test_malformed_verifier_output_is_infrastructure_failure(self):
        directory = self.add_run("malformed")
        PROBE.save(directory / "media-verification.json", {"exitCode": 0, "stdout": "not JSON", "timedOut": False})
        result = PROBE.analyze_experiment(self.output)
        self.assertEqual(result["verifierExecutionFailures"], 1)
        self.assertEqual(result["qualityFailures"], 0)

    def test_metadata_needs_no_video_and_exact_bound_remains_accepted(self):
        self.add_run("metadata", incoming=.5, variant="metadata")
        self.add_run("at-bound", incoming=.5, decoded=.5)
        result = PROBE.analyze_experiment(self.output)
        self.assertEqual(result["qualityFailures"], 0)
        self.assertEqual(result["infrastructureFailures"], 0)

    def test_fixture_overflow_and_invalid_decoder_report_stay_incomplete(self):
        directory = self.add_run("invalid-decoder")
        (self.output / "fixture/draw-trace-overflow.txt").write_text("2\n")
        PROBE.save(directory / "decode-process.json", {"exitCode": 0, "timedOut": False,
                   "stdout": json.dumps({"status": "passed", "frames": None})})
        result = PROBE.analyze_experiment(self.output)
        self.assertEqual(result["infrastructureFailures"], 2)
        self.assertEqual(result["status"], "incomplete")

    def test_offline_cli_preserves_all_original_evidence(self):
        self.add_run("decoded-red", decoded=.6, verification="failed")
        before = {path: path.read_bytes() for path in self.output.rglob("*") if path.is_file()}
        result = subprocess.run([sys.executable, str(SCRIPT), "--reanalyze", str(self.output)],
                                capture_output=True, text=True, timeout=10, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = PROBE.read_json(self.output / "analysis-v2.json")
        self.assertEqual(report["qualityFailures"], 1)
        self.assertEqual(report["decodedGapFailures"], 1)
        self.assertEqual(report["mediaVerifierFailures"], 1)
        self.assertIn("sourceExperimentSHA256", report)
        for path, contents in before.items():
            self.assertEqual(path.read_bytes(), contents, str(path))
        blocked = subprocess.run([sys.executable, str(SCRIPT), "--reanalyze", str(self.output),
                                  "--analysis-out", str(self.output / "experiment.json")],
                                 capture_output=True, text=True, timeout=10, check=False)
        self.assertEqual(blocked.returncode, 1)
        self.assertEqual((self.output / "experiment.json").read_bytes(), before[self.output / "experiment.json"])


if __name__ == "__main__":
    unittest.main()
