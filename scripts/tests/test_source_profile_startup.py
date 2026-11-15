import importlib.util
from pathlib import Path
import signal
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "frame-gap-startup.py"
SPEC = importlib.util.spec_from_file_location("source_startup", SCRIPT)
STARTUP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STARTUP)


class SourceStartupTests(unittest.TestCase):
    def test_source_comparison_runs_one_original_metadata_target_and_leaves_coverage_pending(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "ShareX.app/Contents/MacOS/ShareX"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"fixed app")
            setup = root / "setup.json"
            STARTUP.GAP.save(setup, {"status": "passed"})
            args = SimpleNamespace(out=root / "out", app=root / "ShareX.app", build_settings=root / "settings",
                                   setup_result=setup, commit="test", comparison="source-profile", profile_preflight=root / "docs")
            launches = []

            def harness(arguments, log, environment, timeout):
                launches.append((arguments, environment, timeout))
                native = Path(arguments[arguments.index("--out") + 1])
                (native / "profile").mkdir(parents=True)
                (native / "agent-capture-fixture").write_bytes(b"fixed fixture")
                STARTUP.GAP.save(native / "profile/source-profile.json", {"outcome": "collection_complete"})
                STARTUP.GAP.save(native / "profile-launch.json", {"status": "completed"})
                return {"exitCode": 0, "timedOut": False}

            with mock.patch.object(STARTUP.sys, "platform", "darwin"), \
                 mock.patch.dict(STARTUP.os.environ, {"GITHUB_ACTIONS": "true"}), \
                 mock.patch.object(STARTUP.PROFILE, "validate_documentation"), \
                 mock.patch.object(STARTUP.WORKLOAD, "bounded_harness", side_effect=harness), \
                 mock.patch.object(STARTUP, "analyze_arm", return_value={"errors": [], "result": {
                     "status": "diagnostic_complete", "byteLimitE2EPassed": False}}), mock.patch("builtins.print"):
                self.assertEqual(STARTUP.run_comparison(args), 0)
            self.assertEqual(len(launches), 1)
            arguments, environment, timeout = launches[0]
            self.assertEqual(arguments[arguments.index("--noise-timing") + 1], "before")
            self.assertEqual(arguments[arguments.index("--bitmap-content") + 1], "original")
            self.assertEqual(arguments[arguments.index("--profile-preflight") + 1], args.profile_preflight)
            self.assertEqual(environment["SHAREX_FRAME_GAP_STARTUP_SINK"], "metadata")
            self.assertEqual(environment["SHAREX_FRAME_GAP_BITMAP_COMPONENT_MASK"], "255")
            for name in ("OWNED_BUFFERS", "NV12", "DEEPER_QUEUE"):
                self.assertEqual(environment["SHAREX_FRAME_GAP_" + name], "0")
            self.assertEqual(timeout, 480)
            summary = STARTUP.GAP.read_json(args.out / "comparison.json")
            self.assertEqual(summary["outcome"], "incomplete")
            self.assertFalse(summary["profileCoverageValidated"])
            self.assertFalse(summary["productionE2EPassed"])

    def test_profile_launch_precedes_original_duration_body_without_wait(self):
        with tempfile.TemporaryDirectory() as temporary:
            events = []
            evidence = STARTUP.StartupEvidence(Path(temporary))
            evidence.run = SimpleNamespace(args=SimpleNamespace(profile_preflight=Path("docs")),
                                           start_profile=lambda: events.append("launch"))
            with evidence.step("duration_limit_finalizes_readable_video"):
                events.append("original duration body")
            self.assertEqual(events, ["launch", "original duration body"])
            self.assertEqual(evidence.steps[0]["status"], "passed")
            evidence.events.close()

    def test_target_failure_and_cancellation_hold_before_capture_cleanup(self):
        for cancel in (False, True):
            with self.subTest(cancel=cancel), tempfile.TemporaryDirectory() as temporary:
                order = []
                args = SimpleNamespace(out=Path(temporary) / "native", arm="metadata", noise_timing="before",
                                       bitmap_content="original", writer_lifetime=None)
                run = mock.Mock(request_id="target", verified=[], sessions=[], metrics=[])

                def target():
                    if cancel:
                        signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
                    raise STARTUP.NATIVE.Failure("retained target failure")

                run.stories.side_effect = target
                run.finish_profile.side_effect = lambda: order.append("root helper wait") or []
                run.cleanup.side_effect = lambda **kwargs: order.append("fixture and app cleanup") or []
                with mock.patch.object(STARTUP, "StartupRun", return_value=run):
                    self.assertEqual(STARTUP.run_arm(args), 1)
                self.assertEqual(order, ["root helper wait", "fixture and app cleanup"])
                result = STARTUP.GAP.read_json(args.out / "result.json")
                self.assertEqual(result["status"], "failed")
                self.assertIn("signal" if cancel else "retained target failure", result["reason"])

    def test_normal_user_launch_never_waits_or_registers_privileged_child_for_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = object.__new__(STARTUP.StartupRun)
            run.args = SimpleNamespace(out=Path(temporary), profile_preflight=Path("docs"), commit="test")
            run.fixture = mock.Mock(pid=22)
            run.app = mock.Mock(pid=11)
            run.evidence = mock.Mock()
            run.children = []
            process = mock.Mock(pid=33)
            with mock.patch.object(STARTUP.subprocess, "Popen", return_value=process) as launch, \
                 mock.patch.object(STARTUP.os, "geteuid", return_value=501, create=True):
                run.start_profile()
            self.assertEqual(launch.call_args.args[0][:2], ["/usr/bin/sudo", "-n"])
            self.assertEqual(launch.call_args.args[0][-2:], ["--source-pid", "22"])
            self.assertTrue(launch.call_args.kwargs["start_new_session"])
            self.assertEqual(run.children, [])
            process.wait.assert_not_called()
            process.send_signal.assert_not_called()
            record = STARTUP.GAP.read_json(run.args.out / "profile-launch.json")
            self.assertEqual(record["driverUID"], 501)
            self.assertEqual(record["supervisorLauncherPID"], 33)

    def test_hold_is_bounded_and_never_signals_root_on_timeout_or_inventory_failure(self):
        for inventory_failure in (False, True):
            with self.subTest(inventory_failure=inventory_failure), tempfile.TemporaryDirectory() as temporary:
                run = object.__new__(STARTUP.StartupRun)
                run.args = SimpleNamespace(out=Path(temporary))
                run.profile_launch = {"started": {"monotonicBeforeNs": 100_000_000_000}, "driverWaitLimitSeconds": 55}
                run.profile_process = mock.Mock()
                run.profile_process.wait.side_effect = subprocess.TimeoutExpired("root helper", 5)
                run.app = mock.Mock()
                run.app.poll.return_value = None
                run.fixture = mock.Mock()
                run.fixture.poll.return_value = None
                run.evidence = mock.Mock()
                with mock.patch.object(STARTUP.time, "monotonic", return_value=150), \
                     mock.patch.object(STARTUP.PROFILE, "inventory", return_value={"status": "completed", "cleanupComplete": True},
                                       side_effect=OSError("inventory unavailable") if inventory_failure else None):
                    errors = run.finish_profile()
                run.profile_process.wait.assert_called_once_with(timeout=5)
                self.assertTrue(errors)
                run.profile_process.send_signal.assert_not_called()
                run.profile_process.kill.assert_not_called()
                run.profile_process.terminate.assert_not_called()
                record = STARTUP.GAP.read_json(run.args.out / "profile-launch.json")
                self.assertEqual(record["status"], "incomplete")
                self.assertTrue(record["fixtureAliveAtHoldEnd"])

    def test_successful_launcher_requires_root_completion_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = object.__new__(STARTUP.StartupRun)
            run.args = SimpleNamespace(out=Path(temporary))
            run.profile_launch = {"started": STARTUP.PROFILE.preflight.clock(), "driverWaitLimitSeconds": 55}
            run.profile_process = mock.Mock()
            run.profile_process.wait.return_value = 0
            run.app = mock.Mock()
            run.app.poll.return_value = None
            run.fixture = mock.Mock()
            run.fixture.poll.return_value = None
            run.evidence = mock.Mock()
            with mock.patch.object(STARTUP.PROFILE, "inventory", return_value={"status": "completed", "cleanupComplete": True}):
                errors = run.finish_profile()
            self.assertTrue(errors)
            self.assertEqual(run.profile_launch["status"], "incomplete")


if __name__ == "__main__":
    unittest.main()
