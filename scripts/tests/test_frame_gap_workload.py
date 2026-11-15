import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import uuid


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


WORKLOAD = load("frame_gap_workload", "frame-gap-workload.py")
NATIVE = load("frame_gap_workload_native", "e2e-agent-capture.py")


class WorkloadDiagnosticTests(unittest.TestCase):
    def test_all_three_cycles_run_after_a_red_and_report_missing_trace(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "ShareX.app"
            binary = app / "Contents/MacOS/ShareX"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"immutable diagnostic binary")
            calls = []

            def harness(arguments, log_path, environment, timeout):
                calls.append(arguments)
                evidence = Path(arguments[arguments.index("--out") + 1])
                fixture = evidence / "fixture"
                fixture.mkdir(parents=True)
                WORKLOAD.GAP.save(evidence / "result.json", {"status": "failed" if len(calls) == 1 else "passed"})
                WORKLOAD.GAP.save(fixture / "draw-trace.json", [{"exitUptime": 1}])
                WORKLOAD.GAP.save(fixture / "operation-trace.json", [{"name": "update", "phase": "begin", "uptime": 1}])
                (fixture / "draw-trace-overflow.txt").write_text("0")
                (fixture / "operation-trace-overflow.txt").write_text("0")
                session_id = str(uuid.uuid4()).upper()
                artifact_id = str(uuid.uuid4()).upper()
                snapshot = evidence / "session-snapshots" / session_id
                (snapshot / artifact_id).mkdir(parents=True)
                WORKLOAD.GAP.save(snapshot / "manifest.json", {"id": session_id, "state": "interrupted", "stopReason": "app_restart",
                                  "artifacts": [{"id": artifact_id, "kind": "recording"}]})
                (snapshot / artifact_id / "capture.partial.mp4").write_bytes(b"preserved failed session media")
                self.assertEqual(environment["SHAREX_FRAME_GAP_FIXTURE_TRACE"], "1")
                return {"exitCode": 1 if len(calls) == 1 else 0, "timedOut": False}

            args = SimpleNamespace(app=app, out=root / "output", commit="a" * 40, build_settings=root / "build.json",
                                   codex=Path("codex"), claude=Path("claude"))
            with mock.patch.object(WORKLOAD.sys, "platform", "darwin"), mock.patch.dict(WORKLOAD.os.environ, {"GITHUB_ACTIONS": "true"}), \
                    mock.patch.object(WORKLOAD, "bounded_harness", side_effect=harness), contextlib.redirect_stdout(io.StringIO()):
                code = WORKLOAD.run(args)
            report = WORKLOAD.GAP.read_json(args.out / "workload.json")
            self.assertEqual(code, 1)
            self.assertEqual(len(calls), 6)
            self.assertEqual(report["failedHarnessRuns"], 1)
            self.assertEqual(report["binaryChanges"], 0)
            self.assertEqual(report["missingTraceCount"], 6)
            self.assertEqual(report["diagnosticEvidenceFailures"], 0)
            self.assertEqual(report["abruptExitMissingTraceCount"], 6)
            self.assertEqual(report["harnessStatus"], "failed")
            self.assertEqual(report["diagnosticStatus"], "complete")
            self.assertFalse(WORKLOAD.abrupt_exit_recovery({"state": "interrupted", "stopReason": "target_lost"}))
            for item in report["runs"]:
                missing = item["retainedEvidence"]["missingTraces"][0]
                self.assertEqual(missing["state"], "interrupted")
                self.assertEqual(missing["retainedVideos"][0]["bytes"], len(b"preserved failed session media"))

    def test_opt_in_cleanup_preserves_original_and_copies_all_owned_media(self):
        with tempfile.TemporaryDirectory() as temporary, contextlib.ExitStack() as cleanup:
            root = Path(temporary)
            output = root / "evidence"
            output.mkdir()
            evidence = NATIVE.Evidence(output)
            cleanup.callback(evidence.events.close)
            with mock.patch.dict(NATIVE.os.environ, {"SHAREX_FRAME_GAP_WORKLOAD": "1"}):
                run = NATIVE.Run(SimpleNamespace(), evidence)
            session_id = str(uuid.uuid4()).upper()
            session_root = root / "sessions"
            session = session_root / session_id
            session.mkdir(parents=True)
            run.capabilities = {"sessionRoot": str(session_root)}
            run.owned_session_ids.add(session_id)
            for name in ("manifest.json", "complete.mp4", "failed.partial.mp4"):
                (session / name).write_bytes(name.encode())
            with mock.patch.object(run, "flush_diagnostic_evidence", return_value=[]) as flush:
                self.assertEqual(run.cleanup(failed=False), [])
            flush.assert_called_once()
            for name in ("manifest.json", "complete.mp4", "failed.partial.mp4"):
                self.assertEqual((session / name).read_bytes(), name.encode())
                self.assertEqual((output / "session-snapshots" / session_id / name).read_bytes(), name.encode())

    def test_fixture_cleanup_requests_graceful_quit_and_retains_monotonic_time(self):
        with tempfile.TemporaryDirectory() as temporary, contextlib.ExitStack() as cleanup:
            evidence = NATIVE.Evidence(Path(temporary))
            cleanup.callback(evidence.events.close)
            with mock.patch.dict(NATIVE.os.environ, {"SHAREX_FRAME_GAP_WORKLOAD": "1"}):
                run = NATIVE.Run(SimpleNamespace(), evidence)
                run.fixture = mock.Mock(pid=123)
                run.fixture.poll.return_value = None
                run.fixture.wait.side_effect = lambda timeout: (run.fixture_directory / "draw-trace.json").write_text("[]")
                self.assertEqual(run.flush_diagnostic_evidence(), [])
            command = NATIVE.json.loads((run.fixture_directory / "command.json").read_text())
            self.assertEqual(command["action"], "quit")
            run.fixture.wait.assert_called_once_with(timeout=5)
            events = [json.loads(line) for line in (evidence.directory / "events.jsonl").read_text().splitlines()]
            self.assertTrue(all("monotonicSeconds" in event for event in events))


class RetainedWorkloadTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.output = Path(temporary.name)
        self.source = {"installedBinarySHA256": "a" * 64, "runs": [], "status": "failed",
                       "harnessStatus": "passed", "diagnosticStatus": "incomplete", "missingTraceCount": 6}

    def add_run(self, cycle=1, kind="native", status="passed"):
        evidence = self.output / f"cycle-{cycle:02d}" / kind
        traces = evidence.parent / f"{kind}-traces"
        fixture = evidence / "fixture"
        fixture.mkdir(parents=True)
        traces.mkdir()
        WORKLOAD.GAP.save(evidence / "result.json", {"status": status, "statistics": {"passedSteps": 20}})
        (evidence / "events.jsonl").write_text(json.dumps({"event": "run_finished", "status": status,
                                                          "exitCode": 0 if status == "passed" else 1}) + "\n")
        WORKLOAD.GAP.save(fixture / "draw-trace.json", [{"exitUptime": 10.1}])
        WORKLOAD.GAP.save(fixture / "operation-trace.json", [{"name": "update", "phase": "begin", "uptime": 10}])
        (fixture / "draw-trace-overflow.txt").write_text("0")
        (fixture / "operation-trace-overflow.txt").write_text("0")
        session_id, artifact_id = (str(uuid.uuid4()).upper() for _ in range(2))
        snapshot = evidence / "session-snapshots" / session_id
        (snapshot / artifact_id).mkdir(parents=True)
        WORKLOAD.GAP.save(snapshot / "manifest.json", {"id": session_id, "state": "completed", "stopReason": "user_stop",
                          "artifacts": [{"id": artifact_id, "kind": "recording", "state": "completed"}]})
        (snapshot / artifact_id / "capture.mp4").write_bytes(b"original video")
        trace_path = traces / "example-trace.json"
        WORKLOAD.GAP.save(trace_path, {"context": {"videoPath": f"/Users/runner/Library/Application Support/ShareX/AgentSessions/{session_id}/{artifact_id}/capture.partial.mp4"},
                          "callbacks": [], "limits": [], "heartbeats": [], "overflow": 0, "streamErrors": [],
                          "operations": [{"name": "monitor.tick", "phase": "begin", "uptime": 10}], "operationOverflow": 0})
        self.source["runs"].append({"cycle": cycle, "kind": kind, "exitCode": 0,
            "binaryHashBefore": "a" * 64, "binaryHashAfter": "a" * 64,
            "evidence": f"/DO-NOT-OPEN-REMOTE/cycle-{cycle:02d}/{kind}",
            "traceDirectory": f"/DO-NOT-OPEN-REMOTE/cycle-{cycle:02d}/{kind}-traces",
            "result": {"status": "passed"}, "retainedEvidence": {"missingTraces": ["obsolete join result"]}})
        WORKLOAD.GAP.save(self.output / "workload.json", self.source)
        return evidence, traces, session_id, artifact_id, trace_path

    def test_trace_joins_both_nested_session_and_artifact_ids(self):
        evidence, traces, session_id, artifact_id, _ = self.add_run()
        result = WORKLOAD.retained_evidence(evidence, traces)
        self.assertEqual(result["missingTraces"], [])
        self.assertEqual(result["unmatchedTraces"], [])
        self.assertEqual(result["traces"][0]["sessionID"], session_id)
        self.assertEqual(result["traces"][0]["artifactID"], artifact_id)
        self.assertTrue(result["traces"][0]["manifestMatched"])
        self.assertEqual(result["recordingSessions"][session_id]["retainedVideos"][0]["bytes"], len(b"original video"))

    def test_a_different_artifact_in_same_session_cannot_satisfy_coverage(self):
        evidence, traces, session_id, _, trace_path = self.add_run()
        trace = WORKLOAD.GAP.read_json(trace_path)
        trace["context"]["videoPath"] = f"/Users/runner/{session_id}/{uuid.uuid4()}/capture.partial.mp4"
        WORKLOAD.GAP.save(trace_path, trace)
        result = WORKLOAD.retained_evidence(evidence, traces)
        self.assertEqual(len(result["missingTraces"]), 1)
        self.assertEqual(len(result["unmatchedTraces"]), 1)
        self.assertFalse(result["traces"][0]["manifestMatched"])

    def test_offline_cli_uses_local_raw_files_and_preserves_originals(self):
        for cycle in range(1, 4):
            for kind in ("native", "clients"):
                self.add_run(cycle, kind, status="failed" if cycle == 1 and kind == "native" else "passed")
        before = {path: path.read_bytes() for path in self.output.rglob("*") if path.is_file()}
        result = subprocess.run([sys.executable, str(WORKLOAD.ROOT / "frame-gap-workload.py"), "--reanalyze", str(self.output)],
                                capture_output=True, text=True, timeout=10, check=False)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stderr, "")
        report = WORKLOAD.GAP.read_json(self.output / "workload-analysis-v2.json")
        self.assertEqual(report["failedHarnessRuns"], 1)
        self.assertEqual(report["missingTraceCount"], 0)
        self.assertEqual(report["unmatchedTraceCount"], 0)
        self.assertEqual(report["harnessStatus"], "failed")
        self.assertEqual(report["diagnosticStatus"], "complete")
        self.assertEqual(report["originalVerdicts"]["missingTraceCount"], 6)
        self.assertIn("sourceWorkloadSHA256", report)
        for item in report["runs"]:
            self.assertTrue(Path(item["evidence"]).resolve().is_relative_to(self.output.resolve()))
            self.assertIn("DO-NOT-OPEN-REMOTE", item["originalEvidencePath"])
        for path, contents in before.items():
            self.assertEqual(path.read_bytes(), contents, str(path))
        blocked = subprocess.run([sys.executable, str(WORKLOAD.ROOT / "frame-gap-workload.py"),
                                  "--reanalyze", str(self.output), "--analysis-out", str(self.output / "workload.json")],
                                 capture_output=True, text=True, timeout=10, check=False)
        self.assertEqual(blocked.returncode, 1)
        self.assertEqual((self.output / "workload.json").read_bytes(), before[self.output / "workload.json"])


if __name__ == "__main__":
    unittest.main()
