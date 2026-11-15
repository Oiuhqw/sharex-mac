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


SCRIPT = Path(__file__).resolve().parents[1] / "e2e-desktop-maintenance.py"
SPEC = importlib.util.spec_from_file_location("desktop_maintenance_e2e", SCRIPT)
DRIVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DRIVER)


class PermissionProofTests(unittest.TestCase):
    def setUp(self):
        self.helper = Path("/tmp/independent-helper")
        self.app = {"client": DRIVER.BUNDLE_ID, "service": "kTCCServiceScreenCapture", "auth_value": 2}
        self.witness = {"client": str(self.helper), "service": "kTCCServiceAccessibility", "auth_value": 2}
        self.before = {"system": [self.app, self.witness], "user": []}
        self.after = {"system": [self.witness], "user": []}

    def test_proves_app_reset_while_helper_permissions_stay(self):
        DRIVER.require_permission_removed(self.before, self.after, self.helper)

    def test_preexisting_missing_grant_does_not_count_as_reset(self):
        with self.assertRaisesRegex(DRIVER.Failure, "No actual bundle-scoped"):
            DRIVER.require_permission_removed(self.after, self.after, self.helper)

    def test_reset_that_leaves_app_permission_fails(self):
        with self.assertRaisesRegex(DRIVER.Failure, "records remain"):
            DRIVER.require_permission_removed(self.before, self.before, self.helper)

    def test_reset_of_unrelated_helper_fails(self):
        with self.assertRaisesRegex(DRIVER.Failure, "unrelated permissions"):
            DRIVER.require_permission_removed(self.before, {"system": [], "user": []}, self.helper)

    def test_no_unrelated_witness_is_not_a_scoped_reset_proof(self):
        with self.assertRaisesRegex(DRIVER.Failure, "No independent helper"):
            DRIVER.require_permission_removed({"system": [self.app]}, {"system": []}, self.helper)

    def test_screen_reset_allows_other_app_permissions_but_uninstall_does_not(self):
        other = {**self.app, "service": "kTCCServiceAccessibility"}
        after = {"system": [other, self.witness], "user": []}
        DRIVER.require_permission_removed(self.before, after, self.helper)
        with self.assertRaisesRegex(DRIVER.Failure, "records remain"):
            DRIVER.require_permission_removed(self.before, after, self.helper, all_services=True)


class PermissionProbeTests(unittest.TestCase):
    def connection(self, granted=False):
        connection = mock.Mock()
        connection.getsockopt.return_value = 123

        def respond(frame):
            self.assertEqual(int.from_bytes(frame[:4], "big"), len(frame) - 4)
            request = json.loads(frame[4:])
            self.assertEqual(request["operation"], "capabilities")
            response = json.dumps({"version": 1, "id": request["id"], "ok": True,
                                   "result": {"access": {"screenRecordingGranted": granted}}}).encode()
            connection.makefile.return_value = io.BytesIO(len(response).to_bytes(4, "big") + response)

        connection.sendall.side_effect = respond
        return connection

    def test_permission_is_read_from_the_exact_socket_peer(self):
        for granted in (False, True):
            with self.subTest(granted=granted):
                result = DRIVER.permission_probe_response(self.connection(granted), 123)
                self.assertEqual(result["socketPeerPID"], 123)
                self.assertIs(result["capabilities"]["access"]["screenRecordingGranted"], granted)

    def test_wrong_socket_peer_is_rejected_before_sending_a_request(self):
        connection = self.connection()
        with self.assertRaisesRegex(DRIVER.Failure, "another process"):
            DRIVER.permission_probe_response(connection, 456)
        connection.sendall.assert_not_called()

    def test_truncated_or_unbounded_response_cannot_pass(self):
        for frame, reason in ((b"\x00", "frame header"),
                              ((1_048_577).to_bytes(4, "big"), "frame limit"),
                              ((20).to_bytes(4, "big") + b"{}", "incomplete")):
            with self.subTest(reason=reason):
                connection = self.connection()
                connection.sendall.side_effect = None
                connection.makefile.return_value = io.BytesIO(frame)
                with self.assertRaisesRegex(DRIVER.Failure, reason):
                    DRIVER.permission_probe_response(connection, 123)

    def test_wrong_request_id_cannot_pass(self):
        connection = self.connection()
        connection.sendall.side_effect = None
        response = json.dumps({"version": 1, "id": str(uuid.uuid4()), "ok": True, "result": {}}).encode()
        connection.makefile.return_value = io.BytesIO(len(response).to_bytes(4, "big") + response)
        with self.assertRaisesRegex(DRIVER.Failure, "request ID changed"):
            DRIVER.permission_probe_response(connection, 123)

    def test_unexpected_grant_after_reset_cannot_regrant_or_resume(self):
        run = DRIVER.Run.__new__(DRIVER.Run)
        run.launch_services_capabilities = mock.Mock(return_value={
            "capabilities": {"access": {"screenRecordingGranted": True}}})
        run.command = mock.Mock()
        run.start_app = mock.Mock()
        with self.assertRaisesRegex(DRIVER.Failure, "still reports"):
            run.restore_permission_after_reset()
        run.command.assert_not_called()
        run.start_app.assert_not_called()

    def test_launch_services_polling_keeps_app_identity_separate_from_the_launcher(self):
        empty = {"applications": [], "pids": []}
        for registered_first in (False, True):
            with self.subTest(registered_first=registered_first):
                run = DRIVER.Run.__new__(DRIVER.Run)
                run.args = SimpleNamespace(app=Path("ShareX.app").resolve())
                run.binary = run.args.app / "Contents/MacOS/ShareX"
                application = {"pid": 123, "bundleID": DRIVER.BUNDLE_ID,
                               "bundlePath": str(run.args.app), "executablePath": str(run.binary), "launchTime": 100}
                owned = {"applications": [application], "pids": [123]}
                registered = {"applications": [application], "pids": []}
                named = {"applications": [], "pids": [123]}
                run.application_processes = mock.Mock(side_effect=[
                    empty, registered if registered_first else named, owned, owned, owned, registered, named, empty])
                original = run.app = mock.Mock()
                original.poll.return_value = 0
                launcher = mock.Mock(pid=456, returncode=0)
                launcher.poll.return_value = None
                launcher.wait.side_effect = lambda timeout: setattr(launcher.poll, "return_value", 0)
                run.launch = mock.Mock(return_value=launcher)
                run.permissions = mock.Mock(return_value={"system": []})
                run.control = mock.Mock()
                run.agent_endpoint = mock.Mock(return_value=Path("agent.sock"))
                run.evidence = mock.Mock()
                with mock.patch.object(DRIVER.time, "time", return_value=100), \
                        mock.patch.object(DRIVER, "socket") as socket_api:
                    socket_api.socket.return_value.__enter__.return_value = self.connection()
                    observation = run.launch_services_capabilities("after-reset")
                self.assertIs(run.app, original)
                self.assertEqual(observation["application"]["pid"], 123)
                self.assertEqual(observation["launcherPID"], 456)
                self.assertEqual(observation["socketPeerPID"], 123)
                run.control.assert_called_once_with("terminate-observed", observedPID=123)
                original.wait.assert_not_called()
                launcher.terminate.assert_not_called()


class LoginProofTests(unittest.TestCase):
    def test_exact_app_url_and_enabled_disposition(self):
        output = """Records for UID 501:
 #1:
   Name: ShareX
   Disposition: [enabled, allowed, visible, notified] (0xf)
   URL: file:///Applications/ShareX.app/
 #2:
   Name: ShareX
   Disposition: [enabled, allowed] (0x3)
   URL: file:///Applications/ShareX-other.app/
 #3:
   Name: ShareX
   Disposition: [disabled, allowed, visible] (0xa)
   URL: file:///Applications/ShareX.app/
"""
        records = DRIVER.login_records(output, Path("/Applications/ShareX.app"))
        self.assertEqual([record["enabled"] for record in records], [True, False])

    def test_escaped_url_matches_actual_path(self):
        output = "#1:\nDisposition: [enabled]\nURL: file:///Applications/ShareX%20Test.app/\n"
        self.assertTrue(DRIVER.login_records(output, Path("/Applications/ShareX Test.app"))[0]["enabled"])

    def test_unknown_disposition_format_fails_instead_of_claiming_removed(self):
        with self.assertRaisesRegex(DRIVER.Failure, "disposition"):
            DRIVER.login_records("#1:\nURL: file:///Applications/ShareX.app/\n", Path("/Applications/ShareX.app"))


class NativeTargetTests(unittest.TestCase):
    def test_fixture_does_not_float_over_the_manual_target_picker(self):
        for mode in ("display", "window"):
            with self.subTest(mode=mode):
                run = DRIVER.Run.__new__(DRIVER.Run)
                run.geometry = {"title": "Unique fixture"}
                run.control = mock.Mock()
                run.open_recording = mock.Mock()
                run.inspect = mock.Mock(return_value={"AXEnabled": 1})
                run.press = mock.Mock()
                run.wait_for = lambda check, *_: check()

                def helper(action, **options):
                    if action == "snapshot":
                        return {"elements": [{"identifier": "recording.refresh", "AXEnabled": 1},
                                             {"identifier": f"recording.target.{mode}.fixture",
                                              "AXValue": "Unique fixture"}]}
                    self.assertEqual(action, "select")
                    self.assertEqual(run.control.call_args, mock.call("front", floating=False))
                    raise StopIteration("Target selection reached")

                run.helper = helper
                with self.assertRaisesRegex(StopIteration, "Target selection reached"):
                    run.start_human(mode)

    def test_selects_exact_fixture_window_from_accessible_row_content(self):
        elements = [{"identifier": "recording.target.window.fixture", "content": "Unique fixture"},
                    {"identifier": "recording.target.window.other", "content": "Settings"},
                    {"identifier": "recording.target.display.first", "title": "Built-in Display"}]
        self.assertEqual(DRIVER.target_identifier(elements, "window", "Unique fixture"), "recording.target.window.fixture")
        self.assertEqual(DRIVER.target_identifier(elements, "display"), "recording.target.display.first")

    def test_missing_or_ambiguous_target_never_falls_back_to_first(self):
        for elements in ([], [{"identifier": "recording.target.display.a"}, {"identifier": "recording.target.display.b"}]):
            with self.subTest(elements=elements), self.assertRaisesRegex(DRIVER.Failure, "Expected one display"):
                DRIVER.target_identifier(elements, "display")

    def test_refresh_can_wait_for_missing_target_but_never_accepts_ambiguity(self):
        self.assertIsNone(DRIVER.target_identifier([], "window", "fixture", required=False))
        with self.assertRaisesRegex(DRIVER.Failure, "Expected one display"):
            DRIVER.target_identifier([{"identifier": "recording.target.display.a"},
                                      {"identifier": "recording.target.display.b"}], "display", required=False)

    def test_snapshot_can_select_combined_accessibility_label(self):
        elements = [{"identifier": "recording.target.window.fixture", "AXValue": "Unique fixture, helper"},
                    {"identifier": "recording.target.window.other", "AXValue": "Settings, ShareX"}]
        self.assertEqual(DRIVER.target_identifier(elements, "window", "Unique fixture", required=False),
                         "recording.target.window.fixture")


class FailedRecordingProofTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.session = {"id": str(uuid.uuid4()).upper(), "origin": "human", "state": "failed", "stopReason": "maintenance",
                        "failure": {"code": "storage_failed", "message": "Cannot publish the completed artifact."},
                        "artifacts": [{"id": str(uuid.uuid4()).upper(), "kind": "recording", "state": "failed"}]}
        folder = self.root / self.session["id"] / self.session["artifacts"][0]["id"]
        folder.mkdir(parents=True)
        self.partial = folder / "capture.partial.mp4"
        self.partial.write_bytes(b"preserved incomplete recording evidence")
        self.blocked = folder / "capture.mp4"
        self.run = DRIVER.Run.__new__(DRIVER.Run)
        self.run.root = self.root

    def test_collision_fixture_preserves_partial_and_removes_only_its_empty_directory(self):
        before = self.partial.read_bytes()
        with self.run.blocked_recording_publish(self.session) as (partial, blocked):
            self.assertEqual(partial, self.partial)
            self.assertEqual(blocked, self.blocked)
            DRIVER.require_failed_recording(self.session, partial, blocked)
        self.assertFalse(self.blocked.exists())
        self.assertEqual(self.partial.read_bytes(), before)

    def test_collision_fixture_removes_its_directory_after_failure(self):
        with self.assertRaisesRegex(RuntimeError, "evaluation failed"):
            with self.run.blocked_recording_publish(self.session):
                raise RuntimeError("evaluation failed")
        self.assertFalse(self.blocked.exists())
        self.assertTrue(self.partial.is_file())

    def test_collision_fixture_does_not_replace_an_existing_movie(self):
        self.blocked.write_bytes(b"existing evidence")
        with self.assertRaises(FileExistsError):
            with self.run.blocked_recording_publish(self.session):
                self.fail("Existing publication destination was admitted")
        self.assertEqual(self.blocked.read_bytes(), b"existing evidence")

    def test_collision_fixture_does_not_delete_unexpected_files(self):
        with self.assertRaisesRegex(DRIVER.Failure, "reserved recording destination"):
            with self.run.blocked_recording_publish(self.session):
                (self.blocked / "unexpected").write_bytes(b"preserve me")
        self.assertEqual((self.blocked / "unexpected").read_bytes(), b"preserve me")

    def test_failure_proof_rejects_success_state_or_published_artifact(self):
        self.blocked.mkdir()
        with self.assertRaisesRegex(DRIVER.Failure, "failed manual recording"):
            DRIVER.require_failed_recording({**self.session, "state": "completed"}, self.partial, self.blocked)
        for mutation in ({"state": "completed"}, {"path": "/tmp/capture.mp4"}, {"sha256": "claimed-success"}):
            artifact = {**self.session["artifacts"][0], **mutation}
            with self.subTest(mutation=mutation), self.assertRaisesRegex(DRIVER.Failure, "published movie"):
                DRIVER.require_failed_recording({**self.session, "artifacts": [artifact]}, self.partial, self.blocked)

    def test_failure_proof_rejects_an_unrelated_failure(self):
        self.blocked.mkdir()
        session = {**self.session, "failure": {"code": "storage_failed", "message": "Disk unavailable"}}
        with self.assertRaisesRegex(DRIVER.Failure, "reason other than"):
            DRIVER.require_failed_recording(session, self.partial, self.blocked)

    def test_failure_proof_requires_preserved_nonempty_partial(self):
        self.blocked.mkdir()
        self.partial.write_bytes(b"")
        with self.assertRaisesRegex(DRIVER.Failure, "lost its real partial"):
            DRIVER.require_failed_recording(self.session, self.partial, self.blocked)

    @unittest.skipUnless(sys.platform == "darwin", "Requires real macOS immutable-file semantics.")
    def test_immutable_bundle_refuses_move_and_clears_flag_after_failure(self):
        app = self.root / "ShareX.app"
        app.mkdir()
        self.run.args = SimpleNamespace(app=app)
        self.run.command = lambda command: subprocess.run(command, check=True, capture_output=True)
        with self.assertRaisesRegex(RuntimeError, "evaluation failed"):
            with self.run.immutable_bundle():
                with self.assertRaises(PermissionError):
                    app.rename(self.root / "moved.app")
                raise RuntimeError("evaluation failed")
        app.rename(self.root / "moved.app")


class PreservationProofTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / "ShareX.app"
        (self.app / "Contents").mkdir(parents=True)
        (self.app / "Contents" / "fixture").write_bytes(b"owned bundle")

    def test_hashes_detect_changed_bytes_and_removed_empty_folder(self):
        (self.app / "empty").mkdir()
        before = DRIVER.tree_hashes(self.app)
        (self.app / "empty").rmdir()
        self.assertNotEqual(DRIVER.tree_hashes(self.app), before)
        (self.app / "empty").mkdir()
        (self.app / "Contents" / "fixture").write_bytes(b"changed bundle")
        self.assertNotEqual(DRIVER.tree_hashes(self.app), before)

    def test_trash_requires_exact_identity_and_complete_contents(self):
        expected = DRIVER.tree_hashes(self.app)
        metadata = self.app.stat()
        identity = metadata.st_dev, metadata.st_ino
        trash = self.root / "Trash"
        trash.mkdir()
        target = trash / "ShareX 2.app"
        self.app.rename(target)
        self.assertEqual(DRIVER.exact_trashed_bundle(trash, identity, expected), target)
        (target / "Contents" / "fixture").write_bytes(b"wrong bytes")
        with self.assertRaisesRegex(DRIVER.Failure, "contents differ"):
            DRIVER.exact_trashed_bundle(trash, identity, expected)

    def test_different_inode_with_identical_name_cannot_pass_trash_check(self):
        trash = self.root / "Trash"
        trash.mkdir()
        with self.assertRaisesRegex(DRIVER.Failure, "exact running app inode"):
            DRIVER.exact_trashed_bundle(trash, (0, 0), DRIVER.tree_hashes(self.app))

    def test_bundle_fixture_restores_original_when_the_test_raises(self):
        run = DRIVER.Run.__new__(DRIVER.Run)
        run.args = SimpleNamespace(app=self.app)
        expected = DRIVER.tree_hashes(self.app)
        with self.assertRaisesRegex(RuntimeError, "test failed"):
            with run.replaced_bundle():
                self.assertTrue((self.app / "unrelated-file.txt").is_file())
                raise RuntimeError("test failed")
        self.assertEqual(DRIVER.tree_hashes(self.app), expected)
        self.assertEqual(list(self.root.iterdir()), [self.app])

    def test_wrapper_fixture_restores_exact_command_when_the_test_raises(self):
        run = DRIVER.Run.__new__(DRIVER.Run)
        run.binary = self.app / "Contents" / "fixture"
        run.wrapper = self.root / "sharex"
        expected = DRIVER.SETUP.wrapper_content(run.binary.resolve()).encode()
        run.wrapper.write_bytes(expected)
        with self.assertRaisesRegex(RuntimeError, "test failed"):
            with run.foreign_wrapper() as foreign:
                self.assertTrue(foreign.startswith(DRIVER.SETUP.WRAPPER_PREFIX.encode()))
                self.assertNotEqual(foreign, expected)
                raise RuntimeError("test failed")
        self.assertEqual(run.wrapper.read_bytes(), expected)

    def test_wrapper_fixture_refuses_to_replace_a_command_it_does_not_own(self):
        run = DRIVER.Run.__new__(DRIVER.Run)
        run.binary = self.app / "Contents" / "fixture"
        run.wrapper = self.root / "sharex"
        run.wrapper.write_bytes(b"unrelated command")
        with self.assertRaisesRegex(DRIVER.Failure, "does not own"):
            with run.foreign_wrapper():
                self.fail("Unsafe fixture was admitted")
        self.assertEqual(run.wrapper.read_bytes(), b"unrelated command")


@unittest.skipIf(sys.platform == "darwin", "This exercises the unsupported-host gate.")
class HostGateTests(unittest.TestCase):
    def test_non_mac_host_reports_blocked_without_claiming_native_coverage(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run([sys.executable, str(SCRIPT), "--out", temporary],
                                    capture_output=True, text=True, timeout=10, check=False)
            self.assertEqual(result.returncode, 3, result.stderr)
            report = json.loads((Path(temporary) / "result.json").read_text())
            self.assertEqual(report["status"], "blocked")
            self.assertEqual(report["statistics"]["passedSteps"], 0)
            self.assertEqual(report["statistics"]["sessions"], 0)
            self.assertEqual(report["statistics"]["blockedSteps"], 1)

    def test_prior_evidence_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary) / "result.json"
            evidence.write_text('{"prior": true}\n')
            result = subprocess.run([sys.executable, str(SCRIPT), "--out", temporary],
                                    capture_output=True, text=True, timeout=10, check=False)
            self.assertEqual(result.returncode, 3)
            self.assertEqual(evidence.read_text(), '{"prior": true}\n')


if __name__ == "__main__":
    unittest.main()
