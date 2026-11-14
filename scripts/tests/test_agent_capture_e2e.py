import base64
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
import zlib


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


def png_header(width, height):
    fields = width.to_bytes(4, "big") + height.to_bytes(4, "big") + bytes([8, 6, 0, 0, 0])
    chunk = b"IHDR" + fields
    return DRIVER.PNG_SIGNATURE + len(fields).to_bytes(4, "big") + chunk + zlib.crc32(chunk).to_bytes(4, "big")


class ContractNameTests(unittest.TestCase):
    def test_mcp_tool_names_replace_dots_with_underscores(self):
        self.assertEqual([DRIVER.tool_name(operation) for operation in DRIVER.OPERATIONS],
                         ["capabilities", "targets_list", "screenshot", "recording_start",
                          "recording_status", "recording_stop", "session_mark", "artifacts_list"])

    def test_dotted_names_in_instructions_or_descriptions_are_reported(self):
        texts = ["Discover targets with targets_list. Call recording.stop to finalize.", "Use session.mark."]
        self.assertEqual(DRIVER.dotted_tool_mentions(texts), ["recording.stop", "session.mark"])
        self.assertEqual(DRIVER.dotted_tool_mentions(["Call recording_stop to finalize evidence."]), [])

    def test_socket_path_uses_the_darwin_user_temp_directory(self):
        expected = Path("/var/folders/ab/cd/T") / "sharex-agent" / "agent.sock"
        self.assertEqual(DRIVER.agent_socket_path("/var/folders/ab/cd/T/\n"), expected)
        self.assertEqual(DRIVER.agent_socket_path("/var/folders/ab/cd/T"), expected)

    def test_socket_path_rejects_empty_or_relative_getconf_output(self):
        for output in ("", "\n", "var/folders/T/"):
            with self.subTest(output=output), self.assertRaisesRegex(DRIVER.Failure, "absolute directory"):
                DRIVER.agent_socket_path(output)


class StorageCountTests(unittest.TestCase):
    def test_storage_counts_are_returned(self):
        capabilities = {"storage": {"sessionCount": 4, "sessionLimit": 2048, "unreadableSessions": 1}}
        self.assertEqual(DRIVER.storage_counts(capabilities),
                         {"sessionCount": 4, "sessionLimit": 2048, "unreadableSessions": 1})

    def test_missing_negative_boolean_or_fractional_counts_fail(self):
        valid = {"sessionCount": 4, "sessionLimit": 2048, "unreadableSessions": 0}
        for change in ({"sessionCount": None}, {"unreadableSessions": -1}, {"sessionLimit": 0},
                       {"unreadableSessions": True}, {"sessionCount": 4.0}):
            with self.subTest(change=change), self.assertRaisesRegex(DRIVER.Failure, "non-negative integers"):
                DRIVER.storage_counts({"storage": {**valid, **change}})


class ToolResultTests(unittest.TestCase):
    def setUp(self):
        self.request_id = str(uuid.uuid4()).upper()
        self.artifact = {"id": self.request_id, "kind": "screenshot", "widthPixels": 1024, "heightPixels": 768}
        self.structured = {"version": 1, "id": self.request_id, "ok": True,
                           "result": {"id": self.request_id, "artifacts": [self.artifact]}}

    def result(self, *blocks, structured=None):
        structured = structured or self.structured
        text = {"type": "text", "text": json.dumps(structured)}
        return {"structuredContent": structured, "content": [text, *blocks], "isError": not structured["ok"]}

    def image(self, data):
        return {"type": "image", "mimeType": "image/png", "data": base64.b64encode(data).decode()}

    def test_screenshot_carries_text_then_png_image(self):
        preview = DRIVER.tool_result_content(self.result(self.image(png_header(1024, 768))), "screenshot")
        self.assertEqual((preview["width"], preview["height"]), (1024, 768))

    def test_large_screenshot_image_is_scaled_to_the_preview_limit(self):
        self.artifact.update(widthPixels=3840, heightPixels=2160)
        preview = DRIVER.tool_result_content(self.result(self.image(png_header(1568, 882))), "screenshot")
        self.assertEqual((preview["width"], preview["height"]), (1568, 882))

    def test_screenshot_without_a_valid_preview_fails(self):
        cases = {"one block": ((), "one text block and one PNG image block"),
                 "not a PNG": ((self.image(b"GIF89a" + bytes(40)),), "not a PNG"),
                 "too large": ((self.image(png_header(1600, 1200)),), "at most 1568"),
                 "not base64": (({"type": "image", "mimeType": "image/png", "data": "@@@"},), "not base64"),
                 "wrong type": (({"type": "image", "mimeType": "image/jpeg",
                                  "data": base64.b64encode(png_header(10, 10)).decode()},), "not an image/png")}
        for name, (blocks, message) in cases.items():
            with self.subTest(name=name), self.assertRaisesRegex(DRIVER.Failure, message):
                DRIVER.tool_result_content(self.result(*blocks), "screenshot")

    def test_preview_must_match_the_new_artifact_at_preview_scale(self):
        self.artifact.update(widthPixels=3136, heightPixels=1536)
        with self.assertRaisesRegex(DRIVER.Failure, "at preview scale is 1568x768"):
            DRIVER.tool_result_content(self.result(self.image(png_header(1024, 768))), "screenshot")
        self.artifact["id"] = str(uuid.uuid4())
        with self.assertRaisesRegex(DRIVER.Failure, "artifact whose ID equals the request ID"):
            DRIVER.tool_result_content(self.result(self.image(png_header(1568, 768))), "screenshot")

    def test_other_tools_and_failed_screenshots_keep_exactly_one_text_block(self):
        failed = {"version": 1, "id": self.request_id, "ok": False,
                  "error": {"code": "target_not_found", "message": "List targets again."}}
        self.assertIsNone(DRIVER.tool_result_content(self.result(structured=failed), "screenshot"))
        self.assertIsNone(DRIVER.tool_result_content(self.result(), "targets.list"))
        with self.assertRaisesRegex(DRIVER.Failure, "exactly one text block"):
            DRIVER.tool_result_content(self.result(self.image(png_header(10, 10))), "targets.list")

    def test_text_block_must_equal_structured_content(self):
        result = self.result(self.image(png_header(1024, 768)))
        result["content"][0]["text"] = json.dumps({**self.structured, "ok": False})
        with self.assertRaisesRegex(DRIVER.Failure, "text and structured content differ"):
            DRIVER.tool_result_content(result, "screenshot")

    def test_logged_responses_keep_the_image_size_but_not_its_data(self):
        message = {"jsonrpc": "2.0", "id": 4, "result": self.result(self.image(png_header(1024, 768)))}
        logged = DRIVER.loggable(message)
        self.assertEqual(logged["result"]["content"][0], message["result"]["content"][0])
        self.assertRegex(logged["result"]["content"][1]["data"], r"^<\d+ base64 characters>$")
        self.assertNotEqual(message["result"]["content"][1]["data"], logged["result"]["content"][1]["data"])


class NestedFrameTests(unittest.TestCase):
    def test_frame_has_a_big_endian_length_and_the_requested_depth(self):
        request_id = str(uuid.uuid4()).upper()
        frame = DRIVER.nested_frame(request_id, 400)
        body = frame[4:]
        self.assertEqual(int.from_bytes(frame[:4], "big"), len(body))
        request = json.loads(body)
        self.assertEqual((request["version"], request["id"], request["operation"]), (1, request_id, "targets.list"))
        depth, value = 0, request["arguments"]["target"]
        while isinstance(value, list):
            depth += 1
            value = value[0] if value else None
        self.assertEqual(depth, 400)
        self.assertLess(len(frame), 65_536)


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
        self.capabilities = {"access": {"enabled": False},
                             "storage": {"sessionCount": 3, "sessionLimit": 2048, "unreadableSessions": 0}}
        self.connection = mock.MagicMock()
        self.connection.__enter__.return_value = self.connection
        self.connection.connect.side_effect = self.connect
        self.socket = SimpleNamespace(AF_UNIX=1, SOCK_STREAM=1,
                                      socket=mock.Mock(return_value=self.connection))
        for patcher in (mock.patch.object(DRIVER, "socket", self.socket, create=True),
                        mock.patch.object(DRIVER.time, "sleep")):
            patcher.start()
            self.addCleanup(patcher.stop)

    def connect(self, address):
        expected = Path("/var/folders/zz/abc123/T") / "sharex-agent" / "agent.sock"
        self.assertEqual(address, str(expected))
        if self.connect_failures:
            raise self.connect_failures.pop(0)
        self.connected = True

    def cli_calls(self):
        return [call for call in self.run.command.call_args_list if call.args[0][0] == self.run.binary]

    def command(self, command, **options):
        if command[0] == "/usr/bin/getconf":
            self.assertEqual(command, ["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"])
            return {"exitCode": 0, "stdout": "/var/folders/zz/abc123/T/\n"}
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
        self.assertEqual(len(self.cli_calls()), 1)
        self.assertEqual(self.connection.__exit__.call_count, 3)

    def test_endpoint_is_looked_up_once_across_app_restarts(self):
        self.run.start_app()
        self.run.start_app()
        lookups = [call for call in self.run.command.call_args_list if call.args[0][0] == "/usr/bin/getconf"]
        self.assertEqual(len(lookups), 1)

    def test_capabilities_without_storage_counts_fail_startup(self):
        del self.capabilities["storage"]
        with self.assertRaisesRegex(DRIVER.Failure, "no storage object"):
            self.run.start_app()

    def test_unavailable_endpoint_times_out_without_calling_the_cli(self):
        self.connection.connect.side_effect = ConnectionRefusedError()
        with mock.patch.object(DRIVER.time, "monotonic", side_effect=range(20)):
            with self.assertRaisesRegex(DRIVER.Failure, "Timed out waiting for agent socket"):
                self.run.start_app()
        self.assertEqual(self.cli_calls(), [])
        self.assertIsNone(self.run.capabilities)

    def test_owned_app_exit_stops_readiness_without_calling_the_cli(self):
        self.app.poll.return_value = 1
        with self.assertRaisesRegex(DRIVER.Failure, "exited during startup"):
            self.run.start_app()
        self.assertEqual(self.cli_calls(), [])

    def test_unexpected_socket_error_is_not_retried(self):
        self.connection.connect.side_effect = PermissionError("Endpoint is not accessible")
        with self.assertRaisesRegex(PermissionError, "Endpoint is not accessible"):
            self.run.start_app()
        self.connection.connect.assert_called_once()
        self.assertEqual(self.cli_calls(), [])

    def test_extra_app_blocks_capabilities_and_cleanup_only_stops_owned_children(self):
        self.running["stdout"] = "5623\n5626\n"
        with self.assertRaisesRegex(DRIVER.Failure, "only the owned ShareX app PID"):
            self.run.start_app()
        self.assertEqual(self.cli_calls(), [])
        with mock.patch.object(DRIVER, "stop_process") as stop:
            self.assertEqual(self.run.cleanup(failed=True), [])
        stop.assert_called_once_with(self.app)

    def test_failed_process_check_stops_before_capabilities(self):
        self.running = {"exitCode": 2, "stdout": ""}
        with self.assertRaisesRegex(DRIVER.Failure, "only the owned ShareX app PID"):
            self.run.start_app()
        self.assertEqual(self.cli_calls(), [])

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
