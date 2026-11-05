"""Portable shell-driver regressions. macOS commands are stubbed, not executed."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from perf_fixture import good_metrics


SCRIPT = Path(__file__).resolve().parents[1] / "perf.sh"
BASH = Path(r"C:\Program Files\Git\bin\bash.exe") if os.name == "nt" else Path("/bin/bash")


class PerfScriptTests(unittest.TestCase):
    def run_driver(self, *, driver_exit=0, output=None, stale=False, context_failure=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "perf.sh"
            shutil.copyfile(SCRIPT, script)
            shutil.copyfile(SCRIPT.with_name("validate-perf.py"), root / "validate-perf.py")
            fake_bin = root / "fake-bin"
            fake_bin.mkdir()
            for command in ("codesign", "defaults", "sudo"):
                stub = fake_bin / command
                stub.write_text("#!/bin/sh\nexit 0\n")
                stub.chmod(0o755)
            for command, context_output in {
                "sw_vers": "ProductVersion: 15.8",
                "uname": "arm64",
                "sysctl": "8",
                "uptime": "up 1 day, load averages: 0.1 0.1 0.1",
                "ps": "PID %CPU RSS COMM\n10 0.1 10000 fixture-process",
            }.items():
                stub = fake_bin / command
                stub.write_text("#!/bin/sh\ncat <<'CONTEXT'\n" + context_output + "\nCONTEXT\n")
                stub.chmod(0o755)
            if context_failure:
                (fake_bin / "sysctl").write_text("#!/bin/sh\nexit 17\n")
            if os.name == "nt":
                python = fake_bin / "python3"
                python.write_text('#!/bin/sh\nexec "$TEST_PYTHON" "$@"\n')
                python.chmod(0o755)
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
                (out / "resources.json").write_text('{"stale": true}')
            env = os.environ.copy()
            env.update({
                "PATH": str(fake_bin) + os.pathsep + env["PATH"],
                "HOME": str(root / "home"),
                "TEST_WRITE_OUTPUT": "0" if output is None else "1",
                "TEST_OUTPUT": output or "",
                "TEST_EXIT": str(driver_exit),
                "TEST_PYTHON": Path(sys.executable).as_posix(),
                "TEST_SCRIPT": script.as_posix(),
            })
            result = subprocess.run([str(BASH), "-c", 'export PATH="$PWD/fake-bin:$PATH"; source "$TEST_SCRIPT"'], cwd=root, env=env,
                                    capture_output=True, text=True, timeout=10)
            if result.returncode:
                result.stderr += "\n".join(path.read_text() for path in sorted((root / "perf-out").glob("runner-*.log")))
            if not context_failure:
                for name in ("runner-before.log", "runner-after.log"):
                    context = (root / "perf-out" / name).read_text()
                    self.assertIn("Logical CPUs: 8", context)
                    self.assertIn("fixture-process", context)
            self.assertFalse((root / "perf-out/results.json").exists())
            self.assertFalse((root / "perf-out/resources.json").exists())
            return result

    def test_successful_driver_with_fresh_metrics_passes(self):
        result = self.run_driver(output=json.dumps(good_metrics()))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_nonzero_driver_with_metrics_fails_with_original_status(self):
        result = self.run_driver(driver_exit=7, output=json.dumps(good_metrics()))
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)

    def test_nonzero_driver_cannot_use_stale_metrics(self):
        result = self.run_driver(driver_exit=9, stale=True)
        self.assertEqual(result.returncode, 9, result.stdout + result.stderr)

    def test_successful_driver_without_metrics_fails(self):
        result = self.run_driver(stale=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_runner_context_fails(self):
        result = self.run_driver(output=json.dumps(good_metrics()), context_failure=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_invalid_metrics_fail(self):
        for output in ("", "not-json", "{}", "[]", "null", '{"display": {"scale": 2}}'):
            with self.subTest(output=output):
                result = self.run_driver(output=output)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
