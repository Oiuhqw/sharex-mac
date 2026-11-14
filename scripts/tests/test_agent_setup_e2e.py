from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import uuid


SCRIPT = Path(__file__).resolve().parents[1] / "e2e-agent-setup.py"
SPEC = importlib.util.spec_from_file_location("agent_setup_e2e", SCRIPT)
DRIVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DRIVER)


class CommandTests(unittest.TestCase):
    def test_registration_preserves_spaces_quotes_and_shell_metacharacters(self):
        binary = "/Applications/ShareX 'QA' $(touch nope).app/Contents/MacOS/ShareX"
        for client, prefix in (("claude", ["claude", "mcp", "add", "--transport", "stdio", "--scope", "user", "sharex", "--"]),
                               ("codex", ["codex", "mcp", "add", "sharex", "--"])):
            with self.subTest(client=client):
                command = DRIVER.NATIVE.registration_command(client, binary)
                self.assertEqual(shlex.split(command), prefix + [binary, "--agent", "mcp"])
                self.assertIn("'\"'\"'", command)

    def test_wrapper_forwards_each_argument_without_shell_expansion(self):
        binary = "/Applications/ShareX QA.app/Contents/MacOS/ShareX"
        content = DRIVER.wrapper_content(binary)
        self.assertEqual(content, "#!/bin/sh\n# ShareX managed CLI v1\n"
                         "exec '/Applications/ShareX QA.app/Contents/MacOS/ShareX' --agent \"$@\"\n")


class HelperTests(unittest.TestCase):
    def test_untrusted_accessibility_is_blocked(self):
        with self.assertRaisesRegex(DRIVER.Blocked, "Accessibility permission"):
            DRIVER.decode_helper({"exitCode": 3, "stdout": json.dumps({"status": "blocked", "reason": "Accessibility permission is missing."})})

    def test_failing_helper_cannot_claim_success(self):
        for response in ({"exitCode": 1, "stdout": '{"status":"passed"}'},
                         {"exitCode": 0, "stdout": '{"status":"failed"}'},
                         {"exitCode": 0, "stdout": '{"status":"blocked"}'}):
            with self.subTest(response=response), self.assertRaises(DRIVER.Failure):
                DRIVER.decode_helper(response)

    def test_non_json_output_cannot_pass(self):
        with self.assertRaisesRegex(DRIVER.Failure, "one JSON result"):
            DRIVER.decode_helper({"exitCode": 0, "stdout": "success\n{}"})

    def test_selected_status_icon_does_not_turn_a_failed_menu_action_into_success(self):
        response = {"status": "failed", "reason": "AXPress failed with code -25204.", "elements": [
            {"role": "AXMenuBarItem", "description": "ShareX", "AXSelected": True},
            {"role": "AXMenuItem", "title": "Settings…", "AXEnabled": True},
        ]}
        with self.assertRaisesRegex(DRIVER.Failure, "AXPress failed with code -25204"):
            DRIVER.decode_helper({"exitCode": 1, "stdout": json.dumps(response)})

    def test_setup_does_not_select_agents_when_the_menu_action_fails(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        evidence = DRIVER.NATIVE.Evidence(Path(temporary.name))
        self.addCleanup(evidence.events.close)
        run = DRIVER.Run(SimpleNamespace(), evidence)
        run.capabilities = {"access": {"enabled": False}}
        with mock.patch.object(run, "start_app"), \
                mock.patch.object(run, "helper", side_effect=DRIVER.Failure("Menu did not open")) as helper, \
                mock.patch.object(run, "access") as access:
            with self.assertRaisesRegex(DRIVER.Failure, "Menu did not open"):
                run.stories()
        helper.assert_called_once_with("menu", title="Settings…")
        access.assert_not_called()
        self.assertEqual(evidence.steps[0]["status"], "failed")


@unittest.skipIf(sys.platform == "win32", "POSIX ownership and executable modes are required.")
class WrapperSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.wrapper = Path(self.temporary.name) / ".local/bin/sharex"
        self.wrapper.parent.mkdir(parents=True)

    def test_unrelated_command_is_blocked_without_modification(self):
        self.wrapper.write_text("#!/bin/sh\necho unrelated\n")
        original = self.wrapper.read_bytes()
        with self.assertRaisesRegex(DRIVER.Blocked, "unrelated command"):
            DRIVER.check_wrapper_destination(self.wrapper)
        self.assertEqual(self.wrapper.read_bytes(), original)

    def test_managed_wrapper_can_be_updated(self):
        self.wrapper.write_text(DRIVER.wrapper_content("/Applications/Old ShareX.app/Contents/MacOS/ShareX"))
        DRIVER.check_wrapper_destination(self.wrapper)

    def test_symbolic_link_command_is_blocked(self):
        target = self.wrapper.parent / "unrelated"
        target.write_text(DRIVER.wrapper_content("/old"))
        self.wrapper.symlink_to(target)
        with self.assertRaisesRegex(DRIVER.Blocked, "unsafe command"):
            DRIVER.check_wrapper_destination(self.wrapper)

    def test_shared_writable_directory_is_blocked(self):
        self.wrapper.parent.chmod(0o777)
        with self.assertRaisesRegex(DRIVER.Blocked, "user-owned real directory"):
            DRIVER.check_wrapper_destination(self.wrapper)


class RecordingEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "sessions"
        self.evidence = Path(self.temporary.name) / "evidence"
        self.evidence.mkdir()
        self.session_id = str(uuid.uuid4()).upper()
        self.directory = self.root / self.session_id
        self.directory.mkdir(parents=True)
        self.movie = self.directory / "recording.mp4"
        self.movie.write_bytes(b"fixture-bytes-for-manifest-check-only")
        self.artifact = {"id": str(uuid.uuid4()), "path": str(self.movie.resolve()), "kind": "recording", "state": "completed",
                         "byteCount": self.movie.stat().st_size, "sha256": DRIVER.NATIVE.digest(self.movie), "durationSeconds": 1.2}
        self.session = {"id": self.session_id, "state": "completed", "acceptedFrames": 18, "artifacts": [self.artifact]}

    def validate(self):
        return DRIVER.validate_recording_files(self.session, self.root, self.evidence)

    def test_completed_recording_bytes_are_preserved(self):
        self.validate()
        files = list(self.evidence.iterdir())
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0].read_bytes(), self.movie.read_bytes())

    def test_hash_mismatch_fails_before_copy(self):
        self.movie.write_bytes(b"changed")
        with self.assertRaisesRegex(DRIVER.Failure, "mismatched bytes"):
            self.validate()
        self.assertFalse(list(self.evidence.iterdir()))

    def test_artifact_outside_owned_session_is_rejected(self):
        other = self.root / "other.mp4"
        other.write_bytes(self.movie.read_bytes())
        self.artifact["path"] = str(other.resolve())
        with self.assertRaisesRegex(DRIVER.Failure, "escaped its session"):
            self.validate()

    def test_incomplete_recording_is_not_success(self):
        self.session["state"] = "interrupted"
        with self.assertRaisesRegex(DRIVER.Failure, "did not complete"):
            self.validate()

    def test_existing_evidence_is_not_overwritten(self):
        self.validate()
        with self.assertRaisesRegex(DRIVER.Failure, "already exists"):
            self.validate()


NOW = 1_794_960_000.0


class ManifestDateTests(unittest.TestCase):
    def test_wire_dates_count_seconds_from_2001_utc(self):
        reference = datetime(2001, 1, 1, tzinfo=timezone.utc).timestamp()
        self.assertEqual(DRIVER.wire_date(reference), 0)
        self.assertEqual(DRIVER.wire_date(reference + 86_400), 86_400)

    def test_aged_manifest_ends_forty_days_ago_and_keeps_its_order(self):
        manifest = {"id": "A", "state": "completed", "createdAt": 816337908.33,
                    "startedAt": 816337908.34, "endedAt": 816337908.47,
                    "artifacts": [{"id": "B", "createdAt": 816337908.4}]}
        aged = DRIVER.aged_manifest(manifest, 40, NOW)
        self.assertAlmostEqual(aged["endedAt"], DRIVER.wire_date(NOW - 40 * 86_400))
        self.assertAlmostEqual(aged["endedAt"] - aged["createdAt"], manifest["endedAt"] - manifest["createdAt"])
        self.assertLess(aged["createdAt"], aged["startedAt"])
        self.assertEqual((aged["state"], aged["artifacts"][0]["id"]), (manifest["state"], "B"))
        self.assertAlmostEqual(aged["endedAt"] - aged["artifacts"][0]["createdAt"], 816337908.47 - 816337908.4)
        self.assertEqual((manifest["endedAt"], manifest["artifacts"]), (816337908.47, [{"id": "B", "createdAt": 816337908.4}]))

    def test_private_json_replaces_the_manifest_without_a_leftover_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text('{"old": true}')
            DRIVER.write_private_json(path, {"endedAt": 1.5})
            self.assertEqual(json.loads(path.read_text()), {"endedAt": 1.5})
            self.assertEqual([item.name for item in Path(directory).iterdir()], ["manifest.json"])
            if sys.platform != "win32":
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)


@unittest.skipIf(sys.platform == "win32", "POSIX directory modes are required.")
class OldSessionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.old_end = DRIVER.wire_date(NOW - 31 * 86_400)

    def session(self, state="completed", mode=0o700, manifest=None, **dates):
        name = str(uuid.uuid4()).upper()
        directory = self.root / name
        directory.mkdir()
        (directory / "manifest.json").write_text(manifest if manifest is not None else json.dumps({"state": state, **dates}))
        directory.chmod(mode)
        self.addCleanup(directory.chmod, 0o700)
        return name

    def test_only_final_readable_sessions_older_than_thirty_days_are_old(self):
        completed = self.session(createdAt=self.old_end - 5, endedAt=self.old_end, artifacts=[{"createdAt": self.old_end - 1}])
        failed_without_end = self.session("failed", createdAt=self.old_end)
        interrupted = self.session("interrupted", createdAt=self.old_end, endedAt=self.old_end)
        self.session(createdAt=self.old_end, endedAt=DRIVER.wire_date(NOW - 86_400))
        self.session(createdAt=self.old_end, endedAt=self.old_end, artifacts=[{"createdAt": DRIVER.wire_date(NOW - 86_400)}])
        self.session("recording", createdAt=self.old_end)
        self.session(mode=0o755, createdAt=self.old_end, endedAt=self.old_end)
        self.session(manifest="{not json")
        (self.root / "requests").mkdir()
        self.assertEqual(DRIVER.old_final_sessions(self.root, NOW), {completed, failed_without_end, interrupted})
        self.assertEqual(len(DRIVER.session_folders(self.root)), 8)


class SettingsTextTests(unittest.TestCase):
    def test_confirmation_reads_the_count_from_any_text_attribute(self):
        elements = [{"role": "AXButton", "title": "Delete Old Captures…"},
                    {"role": "AXStaticText", "AXValue": "Delete 3 captures older than 30 days?"},
                    {"role": "AXGroup", "description": "Delete 3 captures older than 30 days?, Delete, Cancel"}]
        self.assertEqual(DRIVER.confirmation(elements), {"text": "Delete 3 captures older than 30 days?", "count": 3})
        self.assertEqual(DRIVER.confirmation([{"AXValue": "Delete 1 capture older than 30 days?"}])["count"], 1)

    def test_missing_confirmation_waits_and_conflicting_counts_fail(self):
        self.assertIsNone(DRIVER.confirmation([{"title": "Delete Old Captures…"}, {"AXValue": 7}]))
        with self.assertRaisesRegex(DRIVER.Failure, "conflicting delete confirmations"):
            DRIVER.confirmation([{"AXValue": "Delete 2 captures older than 30 days?"},
                                 {"title": "Delete 5 captures older than 30 days?"}])

    def test_no_old_captures_text_must_come_without_a_delete_button(self):
        text = {"role": "AXStaticText", "AXValue": "No captures are older than 30 days."}
        dismiss = {"role": "AXButton", "title": "OK", "identifier": "settings.agents.deleteOld.cancel"}
        self.assertTrue(DRIVER.nothing_old([text, dismiss]))
        self.assertFalse(DRIVER.nothing_old([{"title": "Delete Old Captures…", "identifier": "settings.agents.deleteOld"}]))
        self.assertFalse(DRIVER.nothing_old([{"AXValue": "Delete 2 captures older than 30 days?"},
                                             {"identifier": "settings.agents.deleteOld.confirm"}]))
        with self.assertRaisesRegex(DRIVER.Failure, "offers Delete"):
            DRIVER.nothing_old([text, dismiss, {"title": "Delete", "identifier": "settings.agents.deleteOld.confirm"}])

    def test_storage_status_count(self):
        self.assertEqual(DRIVER.stored_count({"identifier": "settings.agents.storage", "AXValue": "12 captures stored"}), 12)
        with self.assertRaisesRegex(DRIVER.Failure, "captures stored"):
            DRIVER.stored_count({"identifier": "settings.agents.storage", "AXValue": "Storage is unavailable."})


class ReportTests(unittest.TestCase):
    def test_setup_stops_when_the_shared_release_proof_fails(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        evidence = DRIVER.NATIVE.Evidence(Path(temporary.name))
        self.addCleanup(evidence.events.close)
        args = SimpleNamespace(app=Path("/Applications/ShareX.app"), build_settings=Path("release.json"))
        run = DRIVER.Run(args, evidence)
        with mock.patch.object(DRIVER.sys, "platform", "darwin"), \
                mock.patch.object(DRIVER.NATIVE, "installed_release_identity",
                                  side_effect=DRIVER.Failure("Release identity rejected")) as proof:
            with self.assertRaisesRegex(DRIVER.Failure, "Release identity rejected"):
                run.preflight()
        proof.assert_called_once_with(args.app, args.build_settings, run.command)
        self.assertEqual(evidence.steps[0]["status"], "failed")
        self.assertEqual(run.children, [])

    @unittest.skipIf(sys.platform == "darwin", "This check exercises the unsupported-host gate.")
    def test_non_mac_host_emits_blocked_report_without_native_claim(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run([sys.executable, str(SCRIPT), "--out", temporary],
                                    capture_output=True, text=True, timeout=10, check=False)
            self.assertEqual(result.returncode, 3, result.stderr)
            report = json.loads((Path(temporary) / "result.json").read_text())
            self.assertEqual(json.loads(result.stdout)["status"], "blocked")
            self.assertEqual(report["statistics"]["sessions"], 0)
            self.assertEqual(report["statistics"]["passedSteps"], 0)
            self.assertEqual(report["statistics"]["blockedSteps"], 1)
            self.assertIn("did not execute native UI or capture", report["reason"])

    def test_existing_run_evidence_remains_intact(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary) / "result.json"
            evidence.write_text('{"original":true}\n')
            result = subprocess.run([sys.executable, str(SCRIPT), "--out", temporary],
                                    capture_output=True, text=True, timeout=10, check=False)
            self.assertEqual(result.returncode, 3)
            self.assertEqual(evidence.read_text(), '{"original":true}\n')


if __name__ == "__main__":
    unittest.main()
