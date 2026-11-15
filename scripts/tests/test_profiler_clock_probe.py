import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "profiler-clock-probe.py"
SPEC = importlib.util.spec_from_file_location("profiler_clock_probe", SCRIPT)
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class ClockProbeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.docs = self.root / "preflight"
        self.docs.mkdir()
        (self.docs / "preflight.json").write_text(json.dumps({"commit": "test", "outcome": "discovery_complete"}))
        (self.docs / "spindump-manual.plain.txt").write_text("\n".join(PROBE.capability.MANUAL_CLAUSES + PROBE.MANUAL_CLAUSES))
        self.source = self.root / "capability"
        (self.source / "report").mkdir(parents=True)
        (self.source / "capability.json").write_text(json.dumps({"commit": "test", "outcome": "collection_complete"}))
        self.original = b"Steps:            52 (20ms sampling interval)\n\xff\x00binary data"
        self.input = self.source / "report" / "system.spindump.txt"
        self.input.write_bytes(self.original)

    def test_ranges_use_actual_one_based_sample_count(self):
        for steps, middle in ((3, 2), (52, 26), (53, 27)):
            with self.subTest(steps=steps):
                ranges = PROBE.sample_ranges(f"Steps:   {steps} (20ms sampling interval)\n".encode())
                self.assertEqual(ranges, {"first": (1, 1), "middle": (middle, middle), "last": (steps, steps)})
        for content in (b"no Steps header", b"Steps: 2 (20ms sampling interval)", "Steps: ５２ (20ms)".encode()):
            with self.subTest(content=content), self.assertRaises(ValueError):
                PROBE.sample_ranges(content)

    def test_commands_use_only_the_owned_report_and_keep_clock_validation_pending(self):
        children = []

        def child(name, argv, out):
            record = {"argv": list(argv), "status": "completed", "cleanupComplete": True}
            process = mock.Mock(record=record)
            children.append(process)
            return process

        out = self.root / "out"
        with mock.patch.object(PROBE.capability, "OwnedChild", side_effect=child):
            report = PROBE.collect_probe(out, "test", self.docs, self.source, PROBE.capability.Cancellation())
        self.assertEqual(report["outcome"], "commands_complete")
        self.assertFalse(report["productionE2EPassed"])
        self.assertFalse(report["clockMappingValidated"])
        self.assertEqual(report["source"]["steps"], 52)
        for index, (name, sample) in enumerate((("first", 1), ("middle", 26), ("last", 52))):
            self.assertEqual(report["commands"][index]["argv"], [
                "/usr/sbin/spindump", "-i", str(self.input.resolve()), "-indexRange", f"{sample}-{sample}",
                "-timeline", "-displayIdleWorkQueueThreads", "-timelimit", "8", "-o", str(out / f"{name}.spindump.txt")])
            children[index].wait.assert_called_once()
            children[index].close.assert_called_once()
            self.assertEqual(children[index].close.call_args.args[0] - children[index].wait.call_args.args[0], 2)
        self.assertEqual(self.input.read_bytes(), self.original)

    def test_failed_or_timed_out_command_preserves_its_evidence_and_stops(self):
        for status in ("failed", "timed_out"):
            with self.subTest(status=status):
                out = self.root / status

                def child(name, argv, output):
                    (output / "first.stderr.raw").write_bytes(b"native failure\x00")
                    return mock.Mock(record={"argv": list(argv), "status": status, "cleanupComplete": True,
                                             "started": {"wallUTC": "original-clock"}, "stderr": "first.stderr.raw"})

                with mock.patch.object(PROBE.capability, "OwnedChild", side_effect=child) as launch:
                    report = PROBE.collect_probe(out, "test", self.docs, self.source, PROBE.capability.Cancellation())
                self.assertEqual(report["outcome"], "incomplete")
                self.assertEqual(report["commands"][0]["status"], status)
                self.assertEqual(report["commands"][0]["started"]["wallUTC"], "original-clock")
                self.assertEqual((out / "first.stderr.raw").read_bytes(), b"native failure\x00")
                self.assertEqual(json.loads((out / "clock-probe.json").read_text())["commands"], report["commands"])
                launch.assert_called_once()

    def test_incomplete_collection_or_missing_documented_option_starts_no_command(self):
        for missing in ("collection", "manual"):
            with self.subTest(missing=missing), mock.patch.object(PROBE.capability, "OwnedChild") as child:
                if missing == "collection":
                    (self.source / "capability.json").write_text(json.dumps({"commit": "test", "outcome": "incomplete"}))
                else:
                    (self.docs / "spindump-manual.plain.txt").write_text("\n".join(PROBE.capability.MANUAL_CLAUSES))
                report = PROBE.collect_probe(self.root / missing, "test", self.docs, self.source, PROBE.capability.Cancellation())
                self.assertEqual(report["outcome"], "incomplete")
                child.assert_not_called()


if __name__ == "__main__":
    unittest.main()
