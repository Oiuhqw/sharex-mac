import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import uuid


SCRIPT = Path(__file__).resolve().parents[1] / "e2e-agent-capture.py"
SPEC = importlib.util.spec_from_file_location("agent_capture_e2e", SCRIPT)
DRIVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DRIVER)


class ResponseTests(unittest.TestCase):
    def setUp(self):
        self.request_id = str(uuid.uuid4())
        self.response = {"version": 1, "id": self.request_id, "ok": True, "result": {"state": "completed"}}

    def test_matches_the_uuid_without_case_dependency(self):
        response = {**self.response, "id": self.request_id.upper()}
        self.assertEqual(DRIVER.decode_response(response, self.request_id), {"state": "completed"})

    def test_rejects_success_for_a_different_request(self):
        with self.assertRaisesRegex(DRIVER.Failure, "request ID changed"):
            DRIVER.decode_response(self.response, str(uuid.uuid4()))

    def test_does_not_accept_an_expected_error_as_capture_success(self):
        response = {"version": 1, "id": self.request_id, "ok": False,
                    "error": {"code": "permission_denied", "message": "Grant Screen Recording permission."}}
        with self.assertRaisesRegex(DRIVER.Failure, "Agent operation failed"):
            DRIVER.decode_response(response)
        self.assertEqual(DRIVER.decode_response(response, error="permission_denied")["code"], "permission_denied")

    def test_rejects_wrong_error_and_missing_message(self):
        response = {"version": 1, "id": self.request_id, "ok": False,
                    "error": {"code": "busy", "message": ""}}
        with self.assertRaisesRegex(DRIVER.Failure, "Expected permission_denied"):
            DRIVER.decode_response(response, error="permission_denied")
        with self.assertRaisesRegex(DRIVER.Failure, "actionable message"):
            DRIVER.decode_response(response, error="busy")


class FixtureGeometry(unittest.TestCase):
    def setUp(self):
        self.fixture = {"windowBounds": {"X": -1760, "Y": 160, "Width": 640, "Height": 480},
                        "displayBounds": {"x": -1920, "y": 0, "width": 1920, "height": 1080}}
        self.target = {"widthPoints": 1920, "heightPoints": 1080, "pixelScale": 2}

    def expectation(self, mode, kind="screenshot", target=None):
        return DRIVER.media_expectation(self.fixture, target or self.target, mode, kind, [0])


class GeometryTests(FixtureGeometry):
    def test_region_uses_display_local_points_on_a_negative_origin_display(self):
        result = self.expectation("region")
        self.assertEqual((result["width"], result["height"]), (768, 576))
        self.assertAlmostEqual(result["anchors"][0]["x"], 1 / 6)
        self.assertAlmostEqual(result["anchors"][0]["y"], 1 / 6)
        self.assertAlmostEqual(result["anchors"][3]["x"], 5 / 6)
        self.assertEqual((result["marker"]["x"], result["marker"]["y"]), (0.5, 0.5))

    def test_display_anchor_accounts_for_fixture_offset(self):
        result = self.expectation("display")
        self.assertEqual((result["width"], result["height"]), (3840, 2160))
        self.assertAlmostEqual(result["marker"]["x"], (160 + 320) / 1920)
        self.assertAlmostEqual(result["marker"]["y"], (160 + 240) / 1080)

    def test_window_capture_excludes_global_display_offsets(self):
        result = self.expectation("window")
        self.assertEqual((result["width"], result["height"]), (1280, 960))
        self.assertAlmostEqual(result["anchors"][0]["x"], 0.3)
        self.assertAlmostEqual(result["anchors"][3]["y"], 0.7)

    def test_video_preserves_aspect_ratio_and_even_output_dimensions(self):
        target = {"widthPoints": 3024, "heightPoints": 1964, "pixelScale": 2}
        result = self.expectation("display", "recording", target)
        self.assertEqual((result["width"], result["height"]), (3324, 2160))
        self.assertLess(abs(result["width"] / result["height"] - 3024 / 1964), 0.001)

    def test_png_is_not_silently_downscaled_to_the_video_limit(self):
        target = {"widthPoints": 3024, "heightPoints": 1964, "pixelScale": 2}
        result = self.expectation("display", target=target)
        self.assertEqual((result["width"], result["height"]), (6048, 3928))


class StaticWindowTests(FixtureGeometry):
    def setUp(self):
        super().setUp()
        self.before = {"mode": "static", "pid": 123, "windowID": 456, "draws": 40,
                       "tick": 40, "stage": 0, "uptime": 100.0}
        self.stop = {**self.before, "uptime": 102.5}
        self.after = {**self.before, "uptime": 102.8}

    def proof(self):
        return DRIVER.static_window_proof(self.before, self.stop, self.after)

    def test_static_expectation_requires_playback_through_stop(self):
        result = DRIVER.media_expectation(self.fixture, self.target, "window", "recording", [0],
                                          static_window=self.proof())
        self.assertEqual(result["motion"], "static")
        self.assertEqual(result["minimumDuration"], 2.5)
        self.assertEqual(result["staticWindow"]["after"]["draws"], 40)
        self.assertAlmostEqual(result["anchors"][-2]["x"], 0.45)
        self.assertEqual(result["anchors"][-2]["rgb"], [255, 255, 255])
        self.assertEqual(result["anchors"][-1]["rgb"], [0, 0, 0])

    def test_one_stage_without_static_proof_keeps_animated_checks(self):
        result = self.expectation("window", "recording")
        self.assertEqual(result["motion"], "animated")
        self.assertNotIn("staticWindow", result)

    def test_changed_draws_tick_stage_or_identity_cannot_unlock_sparse_validation(self):
        for field in ("draws", "tick", "stage", "pid", "windowID"):
            with self.subTest(field=field):
                changed = {**self.after, field: self.after[field] + 1}
                with self.assertRaisesRegex(DRIVER.Failure, "Static fixture changed"):
                    DRIVER.static_window_proof(self.before, self.stop, changed)

    def test_animated_or_never_drawn_fixture_is_rejected(self):
        for change in ({"mode": "animated"}, {"draws": 0}):
            with self.subTest(change=change), self.assertRaisesRegex(DRIVER.Failure, "drawn fixture in static mode"):
                DRIVER.static_window_proof({**self.before, **change}, self.stop, self.after)

    def test_short_unordered_or_nonfinite_window_is_rejected(self):
        for stop, after in ((101.9, 102.8), (102.5, 102.4), (float("nan"), 102.8)):
            with self.subTest(stop=stop, after=after), self.assertRaisesRegex(DRIVER.Failure, "two seconds"):
                DRIVER.static_window_proof(self.before, {**self.stop, "uptime": stop}, {**self.after, "uptime": after})

    def test_invalid_proof_cannot_be_injected_into_media_expectation(self):
        proof = self.proof()
        proof["after"]["draws"] += 1
        with self.assertRaisesRegex(DRIVER.Failure, "Static fixture changed"):
            DRIVER.media_expectation(self.fixture, self.target, "window", "recording", [0], static_window=proof)

    def test_static_exception_does_not_apply_to_animated_stages_or_display_capture(self):
        for mode, kind, stages in (("window", "recording", [0, 1, 2]), ("display", "recording", [0]),
                                   ("window", "screenshot", [0])):
            with self.subTest(mode=mode, kind=kind, stages=stages):
                with self.assertRaisesRegex(DRIVER.Failure, "one unchanged window recording stage"):
                    DRIVER.media_expectation(self.fixture, self.target, mode, kind, stages, static_window=self.proof())


class InstalledReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.app = self.root / "Applications/ShareX.app"
        self.binary = self.app / "Contents/MacOS/ShareX"
        self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(b"recorded Release product")
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleExecutable": "ShareX", "CFBundleIdentifier": "test.sharex"}, stream)
        self.built = self.root / "build/ShareX"
        self.built.parent.mkdir()
        self.built.write_bytes(self.binary.read_bytes())
        self.settings_path = self.root / "build-settings.json"
        self.entries = [{"target": "ShareX", "buildSettings": {"CONFIGURATION": "Release",
                         "TARGET_BUILD_DIR": str(self.built.parent), "EXECUTABLE_PATH": self.built.name}}]
        self.strings = "production symbols"
        self.running_exit = 1
        self.command = mock.Mock(side_effect=self.run_command)
        for patcher in (mock.patch.object(DRIVER.Path, "home", return_value=self.root),
                        mock.patch.dict(DRIVER.os.environ, {}, clear=True)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def run_command(self, command, **options):
        if command[0] == "/usr/bin/strings":
            return {"stdout": self.strings, "exitCode": 0}
        if command[0] == "/usr/bin/pgrep":
            return {"stdout": "", "exitCode": self.running_exit}
        if command[0] == "/usr/bin/sw_vers":
            return {"stdout": "test macOS", "exitCode": 0}
        if command[0] == "/usr/bin/codesign":
            return {"stdout": "", "exitCode": 0}
        self.fail(f"Unexpected command {command}")

    def identity(self):
        self.settings_path.write_text(json.dumps(self.entries))
        return DRIVER.installed_release_identity(self.app, self.settings_path, self.command)

    def test_identity_proves_the_installed_binary_and_signature(self):
        identity = self.identity()
        self.assertEqual(identity["binary"], str(self.binary))
        self.assertEqual(identity["installedSHA256"], DRIVER.digest(self.built))
        self.assertEqual(identity["bundleID"], "test.sharex")
        self.command.assert_any_call(["/usr/bin/codesign", "--verify", "--deep", "--strict", self.app])
        self.command.assert_any_call(["/usr/bin/pgrep", "-x", "ShareX"], check=False)

    def test_build_identity_requires_exactly_one_sharex_release_target(self):
        original = self.entries[0]
        cases = ([], [original, original], [{**original, "target": "ShareXTests"}],
                 [{**original, "buildSettings": {**original["buildSettings"], "CONFIGURATION": "Debug"}}])
        for entries in cases:
            with self.subTest(entries=entries), self.assertRaisesRegex(DRIVER.Failure, "exactly one ShareX Release"):
                self.entries = entries
                self.identity()

    def test_installed_build_mismatch_fails_before_signature_or_process_checks(self):
        self.binary.write_bytes(b"a different product")
        with self.assertRaisesRegex(DRIVER.Failure, "differs from the recorded Release"):
            self.identity()
        self.command.assert_not_called()

    def test_e2e_build_flags_cannot_pass(self):
        for flag in ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "OTHER_SWIFT_FLAGS"):
            with self.subTest(flag=flag):
                self.entries[0]["buildSettings"][flag] = "-DSHAREX_E2E"
                with self.assertRaisesRegex(DRIVER.Failure, "production-forbidden"):
                    self.identity()
                del self.entries[0]["buildSettings"][flag]

    def test_e2e_binary_markers_cannot_pass(self):
        for marker in ("--e2e", "E2E PERF", "e2e-helper", "CGVirtualDisplay"):
            with self.subTest(marker=marker), self.assertRaisesRegex(DRIVER.Failure, "production-forbidden"):
                self.strings = marker
                self.identity()

    def test_existing_process_blocks_ownership(self):
        self.running_exit = 0
        with self.assertRaisesRegex(DRIVER.Blocked, "Only this run's app PID"):
            self.identity()

    def test_failed_process_check_cannot_claim_exclusive_ownership(self):
        self.running_exit = 2
        with self.assertRaisesRegex(DRIVER.Failure, "Could not check"):
            self.identity()

    def test_noninstalled_app_is_blocked(self):
        with self.assertRaisesRegex(DRIVER.Blocked, "Install the Release app"):
            DRIVER.installed_release_identity(self.root / "build/ShareX.app", self.settings_path, self.command)

    def test_e2e_environment_is_blocked(self):
        with mock.patch.dict(DRIVER.os.environ, {"SHAREX_E2E": "0"}):
            with self.assertRaisesRegex(DRIVER.Blocked, "Remove SHAREX_E2E"):
                self.identity()


class StartupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.evidence = DRIVER.Evidence(Path(temporary.name))
        self.addCleanup(self.evidence.events.close)
        self.run = DRIVER.Run(SimpleNamespace(), self.evidence)
        self.run.binary = Path("/Applications/ShareX.app/Contents/MacOS/ShareX")
        self.app = mock.Mock(pid=5623)
        self.app.poll.return_value = None
        self.run.children.append(self.app)
        self.run.launch = mock.Mock(return_value=self.app)
        self.run.command = mock.Mock(side_effect=self.command)
        self.connected = False
        self.connect_failures = []
        self.running = {"exitCode": 0, "stdout": "5623\n"}
        self.capabilities = {"access": {"enabled": False}}
        self.connection = mock.MagicMock()
        self.connection.__enter__.return_value = self.connection
        self.connection.connect.side_effect = self.connect
        self.socket = SimpleNamespace(AF_UNIX=1, SOCK_STREAM=1,
                                      socket=mock.Mock(return_value=self.connection))
        for patcher in (mock.patch.object(DRIVER, "socket", self.socket, create=True),
                        mock.patch.object(DRIVER.os, "getuid", return_value=501, create=True),
                        mock.patch.object(DRIVER.time, "sleep")):
            patcher.start()
            self.addCleanup(patcher.stop)

    def connect(self, address):
        expected = Path("/tmp").resolve() / "sharex-agent-501/agent.sock"
        self.assertEqual(address, str(expected))
        if self.connect_failures:
            raise self.connect_failures.pop(0)
        self.connected = True

    def command(self, command, **options):
        if command[0] == "/usr/bin/pgrep":
            self.assertEqual(command, ["/usr/bin/pgrep", "-x", "ShareX"])
            return self.running
        self.assertTrue(self.connected, "CLI ran before the endpoint accepted a connection")
        self.assertEqual(command[:3], [self.run.binary, "--agent", "capabilities"])
        request_id = command[command.index("--request-id") + 1] if "--request-id" in command else str(uuid.uuid4())
        return {"exitCode": 0, "stdout": json.dumps({"version": 1, "id": request_id,
                                                    "ok": True, "result": self.capabilities})}

    def test_delayed_endpoint_is_ready_before_capabilities_can_auto_launch(self):
        self.connect_failures = [FileNotFoundError(), ConnectionRefusedError()]
        self.run.start_app()
        self.run.launch.assert_called_once_with([self.run.binary, "--agent-background"], "app")
        self.assertEqual(self.connection.connect.call_count, 3)
        self.assertEqual(self.run.capabilities, self.capabilities)
        self.assertEqual(sum(call.args[0][0] == self.run.binary for call in self.run.command.call_args_list), 1)
        self.assertEqual(self.connection.__exit__.call_count, 3)

    def test_unavailable_endpoint_times_out_without_calling_the_cli(self):
        self.connection.connect.side_effect = ConnectionRefusedError()
        with mock.patch.object(DRIVER.time, "monotonic", side_effect=range(20)):
            with self.assertRaisesRegex(DRIVER.Failure, "Timed out waiting for agent socket"):
                self.run.start_app()
        self.run.command.assert_not_called()
        self.assertIsNone(self.run.capabilities)

    def test_owned_app_exit_stops_readiness_without_calling_the_cli(self):
        self.app.poll.return_value = 1
        with self.assertRaisesRegex(DRIVER.Failure, "exited during startup"):
            self.run.start_app()
        self.run.command.assert_not_called()

    def test_unexpected_socket_error_is_not_retried(self):
        self.connection.connect.side_effect = PermissionError("Endpoint is not accessible")
        with self.assertRaisesRegex(PermissionError, "Endpoint is not accessible"):
            self.run.start_app()
        self.connection.connect.assert_called_once()
        self.run.command.assert_not_called()

    def test_extra_app_blocks_capabilities_and_cleanup_only_stops_owned_children(self):
        self.running["stdout"] = "5623\n5626\n"
        with self.assertRaisesRegex(DRIVER.Failure, "only the owned ShareX app PID"):
            self.run.start_app()
        self.assertTrue(all(call.args[0][0] == "/usr/bin/pgrep" for call in self.run.command.call_args_list))
        with mock.patch.object(DRIVER, "stop_process") as stop:
            self.assertEqual(self.run.cleanup(failed=True), [])
        stop.assert_called_once_with(self.app)

    def test_failed_process_check_stops_before_capabilities(self):
        self.running = {"exitCode": 2, "stdout": ""}
        with self.assertRaisesRegex(DRIVER.Failure, "only the owned ShareX app PID"):
            self.run.start_app()
        self.assertTrue(all(call.args[0][0] == "/usr/bin/pgrep" for call in self.run.command.call_args_list))

    def test_app_spawned_by_capabilities_cannot_pass_startup(self):
        def command(arguments, **options):
            result = self.command(arguments, **options)
            if arguments[0] == self.run.binary:
                self.running["stdout"] = "5623\n5626\n"
            return result

        self.run.command.side_effect = command
        with self.assertRaisesRegex(DRIVER.Failure, "only the owned ShareX app PID"):
            self.run.start_app()


class ReportTests(unittest.TestCase):
    @unittest.skipIf(sys.platform == "darwin", "This check exercises the explicit unsupported-host gate.")
    def test_non_mac_host_reports_blocked_without_capture(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run([sys.executable, str(SCRIPT), "--out", temporary],
                                    capture_output=True, text=True, timeout=10, check=False)
            self.assertEqual(result.returncode, 3, result.stderr)
            stdout = json.loads(result.stdout)
            report = json.loads((Path(temporary) / "result.json").read_text())
            self.assertEqual(stdout["status"], "blocked")
            self.assertEqual(report["statistics"]["sessions"], 0)
            self.assertEqual(report["statistics"]["passedSteps"], 0)
            self.assertEqual(report["statistics"]["blockedSteps"], 1)
            self.assertIn("did not execute native capture", report["reason"])

    def test_previous_evidence_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            sentinel = Path(temporary) / "result.json"
            sentinel.write_text('{"previous":true}\n')
            result = subprocess.run([sys.executable, str(SCRIPT), "--out", temporary],
                                    capture_output=True, text=True, timeout=10, check=False)
            self.assertEqual(result.returncode, 3, result.stderr)
            self.assertEqual(sentinel.read_text(), '{"previous":true}\n')
            self.assertEqual(json.loads(result.stdout)["status"], "blocked")

    def test_failed_step_stays_failed_in_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = DRIVER.Evidence(Path(temporary))
            with self.assertRaisesRegex(DRIVER.Failure, "pixels differ"):
                with evidence.step("decoded_media"):
                    raise DRIVER.Failure("pixels differ")
            evidence.events.close()
            self.assertEqual(evidence.steps[0]["status"], "failed")
            events = [json.loads(line) for line in (Path(temporary) / "events.jsonl").read_text().splitlines()]
            self.assertEqual(events[-1]["reason"], "pixels differ")
            self.assertEqual(events[-1]["status"], "failed")


if __name__ == "__main__":
    unittest.main()
