from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "run-bounded.py"


class BoundedProcessTests(unittest.TestCase):
    def run_child(self, code, timeout=5):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "child.log"
            start = time.monotonic()
            result = subprocess.run([sys.executable, str(SCRIPT), "--timeout", str(timeout),
                                     "--log", str(log), "--", sys.executable, "-u", "-c", code],
                                    capture_output=True, text=True, timeout=20)
            return result, log.read_text(), time.monotonic() - start

    def test_success_preserves_output(self):
        result, log, _ = self.run_child("print('completed')")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(log.strip(), "completed")

    def test_failure_preserves_status_and_stderr(self):
        result, log, _ = self.run_child("import sys; print('failed', file=sys.stderr); sys.exit(7)")
        self.assertEqual(result.returncode, 7)
        self.assertEqual(log.strip(), "failed")

    def test_hung_child_is_stopped_with_its_last_output(self):
        result, log, elapsed = self.run_child("import time; print('before hang'); time.sleep(60)", timeout=1)
        self.assertEqual(result.returncode, 124)
        self.assertIn("before hang", log)
        self.assertIn("Timed out", result.stdout)
        self.assertLess(elapsed, 18)
