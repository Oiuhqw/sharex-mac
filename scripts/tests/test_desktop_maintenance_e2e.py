import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest


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
