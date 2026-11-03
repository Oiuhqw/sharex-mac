"""Portable shell-driver regressions. macOS commands are stubbed, not executed."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "perf.sh"


class PerfScriptTests(unittest.TestCase):
    def run_driver(self, *, driver_exit=0, output=None, stale=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "perf.sh"
            shutil.copyfile(SCRIPT, script)
            fake_bin = root / "fake-bin"
            fake_bin.mkdir()
            for command in ("codesign", "defaults", "sudo"):
                stub = fake_bin / command
                stub.write_text("#!/bin/sh\nexit 0\n")
                stub.chmod(0o755)
            binary = root / "build/Build/Products/Release/ShareX.app/Contents/MacOS/ShareX"
            binary.parent.mkdir(parents=True)
            binary.write_text(
                "#!/bin/sh\n"
                'if [ "$TEST_WRITE_OUTPUT" = 1 ]; then\n'
                '  printf "%s" "$TEST_OUTPUT" > "$2/perf.json"\n'
                "fi\n"
                'exit "$TEST_EXIT"\n'
            )
            binary.chmod(0o755)
            if stale:
                out = root / "perf-out"
                out.mkdir()
                (out / "perf.json").write_text('{"stale": true}')
                (out / "results.json").write_text('{"pass": true}')
            env = os.environ.copy()
            env.update({
                "PATH": str(fake_bin) + os.pathsep + env["PATH"],
                "HOME": str(root / "home"),
                "TEST_WRITE_OUTPUT": "0" if output is None else "1",
                "TEST_OUTPUT": output or "",
                "TEST_EXIT": str(driver_exit),
            })
            result = subprocess.run(["bash", str(script)], cwd=root, env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertFalse((root / "perf-out/results.json").exists())
            return result

    def test_successful_driver_with_fresh_metrics_passes(self):
        result = self.run_driver(output=json.dumps({"display": {"scale": 2}}))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_nonzero_driver_with_metrics_fails_with_original_status(self):
        result = self.run_driver(driver_exit=7, output='{"display": {"scale": 2}}')
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)

    def test_nonzero_driver_cannot_use_stale_metrics(self):
        result = self.run_driver(driver_exit=9, stale=True)
        self.assertEqual(result.returncode, 9, result.stdout + result.stderr)

    def test_successful_driver_without_metrics_fails(self):
        result = self.run_driver(stale=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_invalid_metrics_fail(self):
        for output in ("", "not-json", "{}", "[]", "null"):
            with self.subTest(output=output):
                result = self.run_driver(output=output)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
