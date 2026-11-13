import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
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


class GeometryTests(unittest.TestCase):
    def setUp(self):
        self.fixture = {"windowBounds": {"X": -1760, "Y": 160, "Width": 640, "Height": 480},
                        "displayBounds": {"x": -1920, "y": 0, "width": 1920, "height": 1080}}
        self.target = {"widthPoints": 1920, "heightPoints": 1080, "pixelScale": 2}

    def expectation(self, mode, kind="screenshot", target=None):
        return DRIVER.media_expectation(self.fixture, target or self.target, mode, kind, [0])

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
