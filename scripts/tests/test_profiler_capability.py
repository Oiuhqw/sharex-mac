import importlib.util
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "profiler-capability.py"
SPEC = importlib.util.spec_from_file_location("profiler_capability", SCRIPT)
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)
HAS_WAIT_API = all(hasattr(os, name) for name in PROBE.WAIT_API)


def python_child(code, *args):
    return (sys.executable, "-u", "-c", code, *map(str, args))


def documentation(directory, commit="test"):
    directory.mkdir()
    (directory / "preflight.json").write_text(json.dumps({"commit": commit, "outcome": "discovery_complete"}))
    (directory / "spindump-manual.plain.txt").write_text("\n".join(PROBE.MANUAL_CLAUSES))
    return directory


class DocumentationTests(unittest.TestCase):
    def test_missing_manual_contract_stops_before_launch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            docs = documentation(root / "preflight")
            (docs / "spindump-manual.plain.txt").write_text("-timeline only")
            with self.assertRaisesRegex(ValueError, "Installed spindump manual"):
                PROBE.validate_documentation(docs, "test")

    def test_old_or_failed_documentation_cannot_authorize_collection(self):
        with tempfile.TemporaryDirectory() as temporary:
            docs = documentation(Path(temporary) / "preflight", commit="older")
            with self.assertRaisesRegex(ValueError, "matching commit"):
                PROBE.validate_documentation(docs, "test")
            (docs / "preflight.json").write_text(json.dumps({"commit": "test", "outcome": "incomplete"}))
            with self.assertRaisesRegex(ValueError, "complete installed-tool discovery"):
                PROBE.validate_documentation(docs, "test")

    def test_unsupported_runtime_retains_evidence_without_launching_children(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(PROBE, "WAIT_API", ("unavailable_wait_api",)), \
             mock.patch.object(PROBE, "OwnedChild") as child:
            root = Path(temporary)
            report = PROBE.collect_probe(root / "out", "test", root / "absent-docs")
            child.assert_not_called()
            self.assertEqual(report["outcome"], "incomplete")
            self.assertIn("WNOWAIT", report["error"]["message"])
            self.assertFalse(report["capabilityValidated"])
            self.assertEqual(json.loads((root / "out" / "capability.json").read_text()), report)

    def test_cli_never_overwrites_existing_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary)
            evidence = out / "capability.json"
            evidence.write_bytes(b"original")
            result = subprocess.run([sys.executable, str(SCRIPT), "--out", str(out), "--preflight", str(out),
                                     "--commit", "test"], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(evidence.read_bytes(), b"original")


@unittest.skipUnless(HAS_WAIT_API, "Owned-group cleanup needs POSIX waitid and WNOWAIT")
class OwnedChildTests(unittest.TestCase):
    def test_nonzero_exit_preserves_raw_bytes_and_reaps_after_group_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary)
            child = PROBE.OwnedChild("failure", python_child(
                "import sys; sys.stdout.buffer.write(b'partial\\xff'); sys.stderr.buffer.write(b'error\\xfe'); sys.exit(7)"), out)
            try:
                self.assertFalse(child.wait(time.monotonic() + 3))
            finally:
                child.close(time.monotonic() + 1)
            self.assertEqual(child.record["exitCode"], 7)
            self.assertEqual(child.record["status"], "failed")
            self.assertTrue(child.record["cleanupComplete"])
            self.assertEqual((out / child.record["stdout"]).read_bytes(), b"partial\xff")
            self.assertEqual((out / child.record["stderr"]).read_bytes(), b"error\xfe")
            with self.assertRaises(ChildProcessError):
                os.waitid(os.P_PID, child.process.pid, os.WEXITED | os.WNOHANG)

    def test_timeout_kills_owned_descendant_and_preserves_unrelated_process(self):
        self.check_descendant_cleanup(parent_exits=False)

    def test_early_parent_exit_still_cleans_owned_descendant(self):
        self.check_descendant_cleanup(parent_exits=True)

    def check_descendant_cleanup(self, parent_exits):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary)
            heartbeat = out / "descendant-heartbeat"
            descendant = ("import pathlib,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                          "p=pathlib.Path(sys.argv[1]); "
                          "exec('while True:\\n p.write_text(str(time.monotonic_ns()))\\n time.sleep(.01)')")
            parent = ("import subprocess,sys,time; "
                      f"subprocess.Popen({list(python_child(descendant, heartbeat))!r}); "
                      "print('partial output',flush=True); "
                      + ("time.sleep(.1)" if parent_exits else "time.sleep(60)"))
            unrelated = subprocess.Popen(python_child("import time; time.sleep(60)"), start_new_session=True)
            child = PROBE.OwnedChild("collector", python_child(parent), out)
            started = time.monotonic()
            try:
                child.wait(time.monotonic() + 0.4)
                self.assertTrue(heartbeat.is_file())
            finally:
                child.close(time.monotonic() + 1)
                unrelated_alive = unrelated.poll() is None
                unrelated.kill()
                unrelated.wait(timeout=2)
            self.assertLess(time.monotonic() - started, 3)
            self.assertTrue(unrelated_alive)
            self.assertTrue(child.record["cleanupComplete"])
            self.assertEqual(child.record["status"], "completed" if parent_exits else "timed_out")
            self.assertIn(b"partial output", (out / child.record["stdout"]).read_bytes())
            retained = heartbeat.read_bytes()
            time.sleep(0.1)
            self.assertEqual(heartbeat.read_bytes(), retained)
            for event in child.record["signals"]:
                self.assertEqual(event["verifiedPGID"], child.process.pid)
                self.assertEqual(event["verifiedSID"], child.process.pid)

    def test_missing_executable_keeps_raw_files_and_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary)
            child = PROBE.OwnedChild("missing", (str(out / "absent"),), out)
            child.close(time.monotonic() + 1)
            self.assertEqual(child.record["status"], "launch_error")
            self.assertTrue(child.record["cleanupComplete"])
            self.assertEqual((out / child.record["stdout"]).read_bytes(), b"")
            self.assertEqual((out / child.record["stderr"]).read_bytes(), b"")

    def test_reaped_child_is_never_signalled(self):
        with tempfile.TemporaryDirectory() as temporary:
            child = PROBE.OwnedChild("finished", python_child("pass"), Path(temporary))
            child.process.wait(timeout=2)
            with mock.patch.object(os, "killpg") as kill_group:
                child.close(time.monotonic() + 1)
                kill_group.assert_not_called()
            self.assertFalse(child.record["cleanupComplete"])


@unittest.skipUnless(HAS_WAIT_API, "Owned-group cleanup needs POSIX waitid and WNOWAIT")
class ProbeLifecycleTests(unittest.TestCase):
    def run_probe(self, collector_code, total_seconds=8):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            docs = documentation(root / "preflight")
            out = root / "out"
            with mock.patch.object(PROBE, "HELPER", python_child("import time; time.sleep(60)")), \
                 mock.patch.object(PROBE, "collector_command", side_effect=lambda pid, path: python_child(collector_code, pid, path)):
                report = PROBE.collect_probe(out, "test", docs, total_seconds=total_seconds)
            self.assertEqual(json.loads((out / "capability.json").read_text()), report)
            files = {str(path.relative_to(out)): path.read_bytes() for path in out.rglob("*") if path.is_file()}
            for path in (out, *out.rglob("*")):
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o755 if path.is_dir() else 0o644)
            return report, files

    def test_complete_collection_keeps_helper_alive_and_claims_no_capability_validation(self):
        report, files = self.run_probe("import os,pathlib,sys,time; "
            "os.kill(int(sys.argv[1]),0); print('requested collection'); "
            "time.sleep(.05); os.kill(int(sys.argv[1]),0); "
            "pathlib.Path(sys.argv[2]).write_bytes(b'uninterpreted timeline\\x00binary')")
        self.assertEqual(report["outcome"], "collection_complete")
        for claim in ("productionE2EPassed", "sourceProfileCollected", "capabilityValidated"):
            self.assertFalse(report[claim])
        self.assertTrue(report["helperAliveAtCollectorExit"])
        self.assertEqual(report["remainingOwnedProcessGroups"], [])
        self.assertEqual(files["report/system.spindump.txt"], b"uninterpreted timeline\x00binary")
        self.assertLessEqual(report["collector"]["exitObserved"]["monotonicAfterNs"],
                             report["helper"]["signals"][0]["requested"]["monotonicBeforeNs"])
        for name in ("collector", "helper", "preInventory", "postInventory"):
            self.assertTrue(report[name]["cleanupComplete"])
            self.assertIn("sha256", report[name]["executable"])
            self.assertLessEqual(report[name]["started"]["monotonicAfterNs"],
                                 report[name]["finished"]["monotonicBeforeNs"])

    def test_collector_failure_keeps_partial_report_and_both_streams(self):
        report, files = self.run_probe("import pathlib,sys; pathlib.Path(sys.argv[2]).write_bytes(b'partial'); "
            "print('started'); print('denied',file=sys.stderr); sys.exit(9)")
        self.assertEqual(report["outcome"], "incomplete")
        self.assertEqual(report["collector"]["exitCode"], 9)
        self.assertEqual(files["report/system.spindump.txt"], b"partial")
        self.assertEqual(files["collector.stdout.raw"], b"started\n")
        self.assertEqual(files["collector.stderr.raw"], b"denied\n")

    def test_collector_timeout_keeps_partial_report_within_total_bound(self):
        started = time.monotonic()
        report, files = self.run_probe("import pathlib,sys,time; pathlib.Path(sys.argv[2]).write_bytes(b'partial'); "
            "print('started'); time.sleep(60)", total_seconds=5.7)
        self.assertLess(time.monotonic() - started, 5.7)
        self.assertEqual(report["outcome"], "incomplete")
        self.assertEqual(report["collector"]["status"], "timed_out")
        self.assertEqual(files["report/system.spindump.txt"], b"partial")
        self.assertTrue(report["collector"]["cleanupComplete"])
        self.assertTrue(report["helper"]["cleanupComplete"])

    def test_zero_exit_without_report_remains_incomplete(self):
        report, _ = self.run_probe("pass")
        self.assertEqual(report["outcome"], "incomplete")
        self.assertEqual(report["collector"]["exitCode"], 0)

    def test_restrictive_umask_and_collector_modes_still_allow_artifact_upload(self):
        previous = os.umask(0o077)
        try:
            report, _ = self.run_probe("import pathlib,sys; p=pathlib.Path(sys.argv[2]); "
                "p.write_bytes(b'raw'); p.chmod(0o600)")
        finally:
            os.umask(previous)
        self.assertEqual(report["outcome"], "collection_complete")

    def test_sigterm_preserves_partial_report_and_cleans_both_owned_groups(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            docs = documentation(root / "preflight")
            out = root / "out"
            collector_code = ("import pathlib,sys,time; pathlib.Path(sys.argv[2]).write_bytes(b'partial'); "
                              "print('ready',flush=True); time.sleep(60)")
            bootstrap = ("import importlib.util,sys; "
                f"spec=importlib.util.spec_from_file_location('probe',{str(SCRIPT)!r}); "
                "probe=importlib.util.module_from_spec(spec); spec.loader.exec_module(probe); "
                f"probe.HELPER={python_child('import time; time.sleep(60)')!r}; "
                f"probe.collector_command=lambda pid,path: {python_child(collector_code)!r}+(str(pid),str(path)); "
                "probe.sys.platform='darwin'; probe.os.geteuid=lambda: 0; "
                f"sys.argv=[{str(SCRIPT)!r},'--out',{str(out)!r},'--preflight',{str(docs)!r},'--commit','test']; "
                "sys.exit(probe.main())")
            supervisor = subprocess.Popen(python_child(bootstrap), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 4
                ready = out / "collector.stdout.raw"
                while time.monotonic() < deadline:
                    if ready.is_file() and b"ready" in ready.read_bytes():
                        break
                    time.sleep(0.02)
                self.assertTrue(ready.is_file() and b"ready" in ready.read_bytes())
                supervisor.send_signal(signal.SIGTERM)
                stdout, stderr = supervisor.communicate(timeout=4)
            finally:
                if supervisor.poll() is None:
                    supervisor.kill()
                    supervisor.wait(timeout=2)
            self.assertEqual(supervisor.returncode, 1, (stdout, stderr))
            report = json.loads((out / "capability.json").read_text())
            self.assertEqual(report["outcome"], "incomplete")
            self.assertEqual(report["error"]["type"], "InterruptedError")
            self.assertEqual(report["remainingOwnedProcessGroups"], [])
            self.assertTrue(report["collector"]["cleanupComplete"])
            self.assertTrue(report["helper"]["cleanupComplete"])
            self.assertEqual((out / "report/system.spindump.txt").read_bytes(), b"partial")


if __name__ == "__main__":
    unittest.main()
