import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import uuid


SPEC = importlib.util.spec_from_file_location("frame_gap_surfaces", Path(__file__).resolve().parents[1] / "frame-gap-surfaces.py")
SURFACES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SURFACES)


def callback(owned):
    row = {"entryUptime": 1.0, "exitUptime": 1.01, "pts": 0.0, "valid": True, "image": True,
           "screen": True, "status": 0, "appended": True, "ownedBuffers": owned, "surfaceID": 10}
    if owned:
        row.update(copyStart=1.001, copyEnd=1.002, copySucceeded=True, copyDisjoint=True,
                   sourceBaseAddress=100, ownedBaseAddress=200, ownedSurfaceID=20,
                   copyWidth=640, copyHeight=480, copyBytes=640 * 480 * 4)
    return row


class SurfaceComparisonTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.built = self.root / "built.app"
        binary = self.built / "Contents/MacOS/ShareX"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"same signed diagnostic binary")
        self.app = self.root / "ShareX.app"
        shutil.copytree(self.built, self.app)
        self.args = SimpleNamespace(app=self.app, built_app=self.built, build_settings=self.root / "build.json",
                                    helper=self.root / "helper", codex=self.root / "codex", claude=self.root / "claude",
                                    out=self.root / "out", commit="a" * 40)
        self.phases = []
        self.commands = []
        self.fail = ("cycle-01-original", "native")
        self.leave_installed = False
        self.break_trace = False
        self.history_overflow = 0

    def harness(self, arguments, log_path, environment, timeout):
        self.commands.append([str(value) for value in arguments])
        log_path.write_text("retained process output", encoding="utf-8")
        if str(arguments[0]) == "/usr/bin/ditto":
            self.assertFalse(self.app.exists())
            shutil.copytree(arguments[1], arguments[2])
        if arguments[0] != sys.executable:
            return {"exitCode": 0, "timedOut": False}
        evidence = Path(arguments[arguments.index("--out") + 1])
        evidence.mkdir()
        phase = evidence.name
        self.phases.append((evidence.parent.name, phase))
        failed = (evidence.parent.name, phase) == self.fail
        SURFACES.GAP.save(evidence / "result.json", {"status": "failed" if failed else "passed",
                          "reason": "Original quality rejection" if failed else None,
                          "steps": [{"name": "original-case", "status": "failed" if failed else "passed"}]})
        event = {"event": "media_decoded", "verification": {"status": "failed" if failed else "passed"}}
        (evidence / "events.jsonl").write_text(json.dumps(event) + "\n", encoding="utf-8")
        if phase in ("native", "clients"):
            self.assertEqual(environment["SHAREX_FRAME_GAP_HEARTBEAT"], "1")
            self.assertEqual(environment["SHAREX_FRAME_GAP_WORKLOAD"], "1")
            self.assertEqual(environment["SHAREX_FRAME_GAP_FIXTURE_TRACE"], "1")
            owned = evidence.parent.name.endswith("-owned")
            self.assertEqual(environment["SHAREX_FRAME_GAP_OWNED_BUFFERS"], str(int(owned)))
            fixture = evidence / "fixture"
            fixture.mkdir()
            SURFACES.GAP.save(fixture / "draw-trace.json", [{"entryUptime": 1, "exitUptime": 1.01}])
            SURFACES.GAP.save(fixture / "operation-trace.json", [{"name": "update", "phase": "begin", "uptime": 1}])
            for name in ("draw-trace-overflow.txt", "operation-trace-overflow.txt"):
                (fixture / name).write_text("0")
            session_id, artifact_id = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
            session = evidence / "session-snapshots" / session_id
            media = session / artifact_id / "capture.partial.mp4"
            media.parent.mkdir(parents=True)
            media.write_bytes(b"all failed and successful session evidence")
            SURFACES.GAP.save(session / "manifest.json", {"id": session_id, "state": "completed", "artifacts": [
                {"id": artifact_id, "kind": "recording", "state": "completed"}]})
            trace = {"callbacks": [callback(owned)], "heartbeats": [1.0, 1.02], "overflow": 0,
                     "history": {"events": [], "overflow": self.history_overflow},
                     "context": {"videoPath": f"/sessions/{session_id}/{artifact_id}/capture.partial.mp4"}}
            if self.break_trace:
                trace["heartbeats"] = []
            SURFACES.GAP.save(Path(environment["SHAREX_FRAME_GAP_TRACE_DIR"]) / "capture-trace.json", trace)
        else:
            self.assertFalse(any(key.startswith("SHAREX_FRAME_GAP_") for key in environment))
        if phase == "maintenance" and not self.leave_installed:
            self.app.rename(self.root / (evidence.parent.name + "-trashed.app"))
        return {"exitCode": 1 if failed else 0, "timedOut": False}

    def run_comparison(self):
        with mock.patch.object(SURFACES.sys, "platform", "darwin"), \
                mock.patch.dict(SURFACES.os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_OS": "macOS", "SHAREX_FRAME_GAP_OWNED_BUFFERS": "foreign"}), \
                mock.patch.object(SURFACES, "APP", self.app), \
                mock.patch.object(SURFACES.WORKLOAD, "bounded_harness", side_effect=self.harness), \
                contextlib.redirect_stdout(io.StringIO()):
            code = SURFACES.run(self.args)
        return code, SURFACES.GAP.read_json(self.args.out / "comparison.json")

    def test_fixed_abba_keeps_all_phases_after_native_failure_and_all_evidence(self):
        code, report = self.run_comparison()
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "collected")
        self.assertEqual(report["harnessStatus"], "failed")
        self.assertEqual(report["qualityFailures"], 1)
        self.assertEqual(report["harnessFailures"], 1)
        self.assertEqual(report["infrastructureFailures"], 0)
        expected = [(f"cycle-{cycle:02d}-{arm}", phase) for cycle, arm in enumerate(("original", "owned", "owned", "original"), 1)
                    for phase in ("setup", "native", "clients", "maintenance")]
        self.assertEqual(self.phases, expected)
        self.assertEqual(sum(row[0] == "/usr/bin/ditto" for row in self.commands), 3)
        self.assertEqual(sum("ci-capture-permissions.sh" in row[1] for row in self.commands if len(row) > 1), 3)
        self.assertEqual(len(list(self.args.out.rglob("*.mp4"))), 8)
        self.assertTrue(all(path.read_bytes() == b"all failed and successful session evidence" for path in self.args.out.rglob("*.mp4")))
        self.assertEqual(len(list(self.root.glob("*-trashed.app"))), 4)
        self.assertEqual(report["cycles"][0]["phases"][1]["originalResult"]["reason"], "Original quality rejection")

    def test_failed_setup_does_not_skip_native_clients_or_maintenance(self):
        self.fail = ("cycle-01-original", "setup")
        code, report = self.run_comparison()
        self.assertEqual(len(self.phases), 16)
        self.assertEqual(report["harnessFailures"], 1)
        self.assertEqual(code, 0)

    def test_existing_app_after_maintenance_stops_without_delete_or_restore(self):
        self.leave_installed = True
        original = SURFACES.bundle_files(self.app)
        code, report = self.run_comparison()
        self.assertEqual(code, 1)
        self.assertEqual(report["status"], "incomplete")
        self.assertEqual(len(self.phases), 4)
        self.assertFalse(any(row[0] == "/usr/bin/ditto" for row in self.commands))
        self.assertEqual(SURFACES.bundle_files(self.app), original)
        self.assertIn("without replacing", report["infrastructureErrors"][0])

    def test_missing_heartbeat_is_incomplete_even_with_quality_results_retained(self):
        self.break_trace = True
        code, report = self.run_comparison()
        self.assertEqual(code, 1)
        self.assertEqual(len(self.phases), 16)
        self.assertEqual(report["qualityFailures"], 1)
        self.assertEqual(report["infrastructureFailures"], 8)

    def test_changed_signed_source_never_overwrites_first_installation(self):
        (self.built / "Contents/MacOS/ShareX").write_bytes(b"different source")
        original = SURFACES.bundle_files(self.app)
        code, report = self.run_comparison()
        self.assertEqual(code, 1)
        self.assertEqual(self.phases, [])
        self.assertEqual(SURFACES.bundle_files(self.app), original)
        self.assertIn("differs", report["infrastructureErrors"][0])

    def test_history_overflow_marks_collection_incomplete_and_preserves_quality_failure(self):
        self.history_overflow = 1
        code, report = self.run_comparison()
        self.assertEqual(code, 1)
        self.assertEqual(report["status"], "incomplete")
        self.assertEqual(len(self.phases), 16)
        self.assertEqual(report["qualityFailures"], 1)
        self.assertEqual(report["infrastructureFailures"], 8)
        for cycle in report["cycles"]:
            for phase in cycle["phases"]:
                if phase["phase"] in ("native", "clients"):
                    self.assertTrue(any("history is missing or overflowed" in error for error in phase["infrastructureErrors"]))

    def test_treatment_requires_disjoint_copy_and_rejects_copy_in_original(self):
        traces = self.root / "traces"
        traces.mkdir()
        trace = {"callbacks": [callback(True)], "heartbeats": [1], "history": {"events": [], "overflow": 0}}
        path = traces / "capture-trace.json"
        SURFACES.GAP.save(path, trace)
        self.assertEqual(SURFACES.treatment_evidence(traces, "owned")["errors"], [])
        del trace["history"]
        SURFACES.GAP.save(path, trace)
        self.assertTrue(any("history" in error for error in SURFACES.treatment_evidence(traces, "owned")["errors"]))
        trace["history"] = {"events": [], "overflow": 0}
        trace["callbacks"][0]["copyDisjoint"] = False
        SURFACES.GAP.save(path, trace)
        self.assertTrue(SURFACES.treatment_evidence(traces, "owned")["errors"])
        trace["callbacks"][0]["ownedBuffers"] = False
        SURFACES.GAP.save(path, trace)
        self.assertTrue(SURFACES.treatment_evidence(traces, "original")["errors"])


if __name__ == "__main__":
    unittest.main()
